#!/usr/bin/env bash
# gen-srcinfo.sh: print .SRCINFO for packaging/aur/PKGBUILD in makepkg's
# --printsrcinfo layout, so the file can be regenerated without makepkg.
# Usage: gen-srcinfo.sh [PKGBUILD] > packaging/aur/.SRCINFO

set -Eeuo pipefail

pkgbuild="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/packaging/aur/PKGBUILD}"
[[ -f $pkgbuild ]] || { printf 'PKGBUILD not found: %s\n' "$pkgbuild" >&2; exit 1; }

bash -c '
	set -Eeuo pipefail
	CARCH=x86_64
	# shellcheck disable=SC1090
	source "$1"
	emit() { local key="$1"; shift; local value; for value in "$@"; do printf "\t%s = %s\n" "$key" "$value"; done; }
	printf "pkgbase = %s\n" "$pkgname"
	emit pkgdesc "$pkgdesc"
	emit pkgver "$pkgver"
	emit pkgrel "$pkgrel"
	emit url "$url"
	emit install "$install"
	emit arch "${arch[@]}"
	emit license "${license[@]}"
	emit makedepends "${makedepends[@]}"
	emit depends "${depends[@]}"
	emit optdepends "${optdepends[@]}"
	emit provides "${provides[@]}"
	emit conflicts "${conflicts[@]}"
	emit noextract "${noextract[@]}"
	emit options "${options[@]}"
	emit source "${source[@]}"
	emit sha256sums "${sha256sums[@]}"
	printf "\npkgname = %s\n" "$pkgname"
' _ "$pkgbuild"
