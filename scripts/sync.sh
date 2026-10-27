#!/bin/bash
# Bring the pacman repository up to date: move every package directory to its
# project's newest GitHub release on the package's channel, build and sign the
# packages that are not published yet, add them to the signed database,
# publish, and remove package files the database no longer lists.
#
# Channels: <name>-prerelease-bin directories follow the newest release
# including prereleases (tags vX.Y.Z-prerelease[.N]), so they also move on to
# the stable release that follows; every other directory follows stable
# releases (tags vX.Y.Z...) only.
#
# Already-published package files are never rebuilt or replaced: pacman caches
# packages by file name, so a changed file under the same name would fail its
# checksum. A PKGBUILD-only fix needs a pkgrel bump.
#
# Usage: scripts/sync.sh
#
# Environment:
#   GPGKEY             Fingerprint of the signing key in the caller's keyring (required).
#   REPO_NAME          Repository name in pacman.conf (default: pyrowave).
#   STORE              "github" (default) publishes to the GITHUB_REPOSITORY release
#                      tagged RELEASE_TAG (default: x86_64) with gh; a directory path
#                      publishes there instead, for local tests.
#   GH_TOKEN           Token for gh and the GitHub API (optional for a directory store).
#
# Runs as a non-root user (makepkg refuses root). Needs base-devel,
# pacman-contrib, jq, curl, gnupg, and github-cli for the github store.

set -euo pipefail

fail()
{
  echo "$1" >&2
  exit 1
}

[ "$(id -u)" -ne 0 ] || fail "Run as a non-root user; makepkg refuses root."
: "${GPGKEY:?Set GPGKEY to the signing key fingerprint}"
export GPGKEY
REPO_NAME=${REPO_NAME:-pyrowave}
STORE=${STORE:-github}
RELEASE_TAG=${RELEASE_TAG:-x86_64}
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/src" "$WORK/build" "$WORK/out" "$WORK/db"
export SRCDEST="$WORK/src" BUILDDIR="$WORK/build" PKGDEST="$WORK/out"

# --- Storage: a GitHub release or, for tests, a directory -------------------

if [ "$STORE" = github ]; then
  : "${GITHUB_REPOSITORY:?Set GITHUB_REPOSITORY (owner/name) for the github store}"
  store_init()
  {
    gh release view "$RELEASE_TAG" -R "$GITHUB_REPOSITORY" >/dev/null 2>&1 ||
      gh release create "$RELEASE_TAG" -R "$GITHUB_REPOSITORY" --latest=false \
        --title "[$REPO_NAME] pacman repository ($RELEASE_TAG)" \
        --notes "Pacman repository files, published by scripts/sync.sh. See README.md to use it."
  }
  store_list() { gh release view "$RELEASE_TAG" -R "$GITHUB_REPOSITORY" --json assets -q '.assets[].name'; }
  store_get() { gh release download "$RELEASE_TAG" -R "$GITHUB_REPOSITORY" -p "$1" -D "$2"; }
  store_put() { gh release upload "$RELEASE_TAG" -R "$GITHUB_REPOSITORY" --clobber "$@"; }
  store_delete() { gh release delete-asset "$RELEASE_TAG" "$1" -R "$GITHUB_REPOSITORY" -y; }
else
  store_init() { mkdir -p "$STORE"; }
  store_list() { find "$STORE" -maxdepth 1 -type f -printf '%f\n'; }
  store_get() { cp "$STORE/$1" "$2/"; }
  store_put() { cp "$@" "$STORE/"; }
  store_delete() { rm -f "$STORE/$1"; }
fi

# The pacman version of a release version: 0.18.0-prerelease.1 is
# 0.18.0prerelease.1, which vercmp orders after 0.17.x and before 0.18.0.
pkgver_of() { printf '%s\n' "${1/-/}"; }

# Newest release version of a GitHub project on a channel, without the 'v'.
# stable: vX.Y.Z... tags of releases not marked as prereleases; prerelease tags
# are skipped even when the release is not marked as a prerelease.
# prerelease: those and vX.Y.Z...-prerelease[.N] tags, marked or not.
latest_release()
{
  local auth=() filter pattern tags version best=
  [ -z "${GH_TOKEN:-}" ] || auth=(-H "Authorization: Bearer $GH_TOKEN")
  if [ "$2" = prerelease ]; then
    filter='.[] | select(.draft | not) | .tag_name'
    pattern='^v[0-9]+(\.[0-9]+)+(-prerelease(\.[0-9]+)?)?$'
  else
    filter='.[] | select((.draft or .prerelease) | not) | .tag_name'
    pattern='^v[0-9]+(\.[0-9]+)+$'
  fi
  tags=$(curl -fsSL "${auth[@]}" "https://api.github.com/repos/$1/releases?per_page=50" |
    jq -r "$filter" | { grep -E "$pattern" || true; } | sed 's/^v//') || return
  while read -r version; do
    [ -n "$version" ] || continue
    if [ -z "$best" ] || [ "$(vercmp "$(pkgver_of "$version")" "$(pkgver_of "$best")")" -gt 0 ]; then
      best=$version
    fi
  done <<<"$tags"
  printf '%s\n' "$best"
}

# --- Update PKGBUILDs and build what is not published -----------------------

db="$WORK/db/$REPO_NAME.db.tar.zst"
files_db="$WORK/db/$REPO_NAME.files.tar.zst"
db_filenames() { bsdtar -xOf "$db" '*/desc' | awk '/^%FILENAME%$/ { getline; print }'; }

store_init
listed=
if store_list | grep -qxF "$REPO_NAME.db.tar.zst"; then
  store_get "$REPO_NAME.db.tar.zst" "$WORK/db"
  store_get "$REPO_NAME.files.tar.zst" "$WORK/db"
  listed=$(db_filenames)
fi
# Published means listed in the database; an uploaded file the database never
# listed (an interrupted run) is rebuilt and replaced.
is_published() { grep -qxF "$1" <<<"$listed"; }

new=()
status=0
for pkgbuild in "$ROOT"/*/PKGBUILD; do
  dir=$(dirname "$pkgbuild")
  name=$(basename "$dir")
  project=$(sed -n 's|^\turl = https://github.com/||p' "$dir/.SRCINFO" | head -n 1)
  current=$(sed -n 's/^pkgver=//p' "$pkgbuild")
  channel=stable
  case $name in *-prerelease-bin) channel=prerelease ;; esac
  latest=$(latest_release "$project" "$channel")
  [ -n "$latest" ] || { echo "$name: no release of $project on the $channel channel" >&2; status=1; continue; }

  order=$(vercmp "$(pkgver_of "$latest")" "$current")
  # A PKGBUILD can be prepared for a release that is not out yet.
  if [ "$order" -lt 0 ]; then
    echo "==> $name: waiting for $current (newest on the $channel channel: $latest)"
    continue
  fi
  # A prepared PKGBUILD has no checksums until its release exists.
  if [ "$order" -gt 0 ] || grep -qxF "sha256sums=('SKIP')" "$pkgbuild"; then
    echo "==> $name: $current -> $latest"
    cp "$pkgbuild" "$WORK/PKGBUILD.$name"
    cp "$dir/.SRCINFO" "$WORK/SRCINFO.$name"
    # A release can be visible before all its assets are uploaded; retry next run.
    if ! "$ROOT/scripts/update-pkgbuild.sh" "$dir" "$latest"; then
      cp "$WORK/PKGBUILD.$name" "$pkgbuild"
      cp "$WORK/SRCINFO.$name" "$dir/.SRCINFO"
      echo "$name: could not update to $latest" >&2
      status=1
      continue
    fi
  fi

  mapfile -t files < <(cd "$dir" && makepkg --packagelist)
  missing=()
  for file in "${files[@]}"; do
    is_published "$(basename "$file")" || missing+=("$file")
  done
  [ ${#missing[@]} -gt 0 ] || { echo "==> $name: published"; continue; }

  echo "==> $name: building ${missing[*]##*/}"
  # One failed package must not hold back the others.
  if ! (cd "$dir" && makepkg --force --nodeps --noconfirm --sign --key "$GPGKEY"); then
    echo "$name: build failed" >&2
    status=1
    continue
  fi
  for file in "${missing[@]}"; do
    [ -f "$file" ] && [ -f "$file.sig" ] || fail "makepkg did not produce $file and its signature"
    new+=("$file")
  done
done

if [ ${#new[@]} -eq 0 ]; then
  echo "==> [$REPO_NAME] is up to date"
  exit "$status"
fi

# --- Database ---------------------------------------------------------------

cp "${new[@]}" "$WORK/db/"
for file in "${new[@]}"; do cp "$file.sig" "$WORK/db/"; done
(cd "$WORK/db" && repo-add --sign --key "$GPGKEY" "$db" "${new[@]##*/}")

# pacman requests <repo>.db and <repo>.files; release assets cannot be symlinks.
for base in "$REPO_NAME.db" "$REPO_NAME.files"; do
  rm -f "$WORK/db/$base" "$WORK/db/$base.sig"
  cp "$WORK/db/$base.tar.zst" "$WORK/db/$base"
  cp "$WORK/db/$base.tar.zst.sig" "$WORK/db/$base.sig"
done

# Packages before the database, so a client never sees an entry whose file is missing.
packages=()
for file in "${new[@]}"; do packages+=("$WORK/db/${file##*/}" "$WORK/db/${file##*/}.sig"); done
store_put "${packages[@]}"
store_put "$WORK/db/$REPO_NAME".{db,files}{,.sig} "$db" "$db.sig" "$files_db" "$files_db.sig"
echo "==> Published ${new[*]##*/}"

# --- Remove package files the database no longer lists ----------------------

listed=$(db_filenames)
while read -r asset; do
  case $asset in
    *.pkg.tar.*)
      grep -qxF "${asset%.sig}" <<<"$listed" || { echo "==> Removing $asset"; store_delete "$asset"; }
      ;;
  esac
done < <(store_list)

exit "$status"
