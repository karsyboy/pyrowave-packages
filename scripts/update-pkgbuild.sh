#!/bin/bash
# Point a package directory at a published release: set pkgver (resetting
# pkgrel for a new version), refresh the checksums from the release assets and
# regenerate .SRCINFO. Needs makepkg and updpkgsums (pacman-contrib) and must
# run as a non-root user.
#
# Usage: scripts/update-pkgbuild.sh <package-dir> <version>   (e.g. pyrolight-bin 6.2.4)

set -euo pipefail

fail()
{
  echo "$1" >&2
  exit 1
}

[ $# -eq 2 ] || fail "Usage: $0 <package-dir> <version>"
VERSION=${2#v}
# pkgver cannot hold '-'; prereleases are not published.
[[ $VERSION =~ ^[0-9]+(\.[0-9]+)+$ ]] || fail "Not a stable release version: $2"

cd "$1"
if [ "$(sed -n 's/^pkgver=//p' PKGBUILD)" != "$VERSION" ]; then
  sed -i -e "s/^pkgver=.*/pkgver=$VERSION/" -e 's/^pkgrel=.*/pkgrel=1/' PKGBUILD
fi
# sync.sh shares its SRCDEST so the build reuses these downloads.
if [ -z "${SRCDEST:-}" ]; then
  SRCDEST=$(mktemp -d)
  trap 'rm -rf "$SRCDEST"' EXIT
fi
SRCDEST=$SRCDEST updpkgsums
makepkg --printsrcinfo > .SRCINFO
