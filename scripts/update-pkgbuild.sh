#!/bin/bash
# Point a package directory at a published release: set pkgver (resetting
# pkgrel for a new version), refresh the checksums from the release assets and
# regenerate .SRCINFO. Needs makepkg and updpkgsums (pacman-contrib) and must
# run as a non-root user.
#
# A PKGBUILD that sets _tag (the *-prerelease-bin packages) also takes
# prerelease versions: 0.18.0-prerelease.1 becomes _tag=v0.18.0-prerelease.1
# and pkgver=0.18.0prerelease.1, which pacman orders before 0.18.0 and which is
# also the version in the file name of the project's nfpm Arch package.
#
# Usage: scripts/update-pkgbuild.sh <package-dir> <version>
#   (e.g. pyrolight-bin 6.2.4, pyroshine-prerelease-bin 0.18.0-prerelease.1)

set -euo pipefail

fail()
{
  echo "$1" >&2
  exit 1
}

[ $# -eq 2 ] || fail "Usage: $0 <package-dir> <version>"
VERSION=${2#v}

cd "$1"
if grep -q '^_tag=' PKGBUILD; then
  [[ $VERSION =~ ^[0-9]+(\.[0-9]+)+(-prerelease(\.[0-9]+)?)?$ ]] || fail "Not a release or prerelease version: $2"
  sed -i "s/^_tag=.*/_tag=v$VERSION/" PKGBUILD
else
  # pkgver cannot hold '-'; stable packages take stable releases only.
  [[ $VERSION =~ ^[0-9]+(\.[0-9]+)+$ ]] || fail "Not a stable release version: $2"
fi
PKGVER=${VERSION/-/}
if [ "$(sed -n 's/^pkgver=//p' PKGBUILD)" != "$PKGVER" ]; then
  sed -i -e "s/^pkgver=.*/pkgver=$PKGVER/" -e 's/^pkgrel=.*/pkgrel=1/' PKGBUILD
fi
# sync.sh shares its SRCDEST so the build reuses these downloads.
if [ -z "${SRCDEST:-}" ]; then
  SRCDEST=$(mktemp -d)
  trap 'rm -rf "$SRCDEST"' EXIT
fi
SRCDEST=$SRCDEST updpkgsums
makepkg --printsrcinfo > .SRCINFO
