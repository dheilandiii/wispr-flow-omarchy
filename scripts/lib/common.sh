# shellcheck shell=bash
# Shared helpers for the repo-side scripts (install.sh, uninstall.sh,
# scripts/*.sh). The installed bin/ scripts stay self-contained on purpose.
#
# Sourcing contract: the caller defines nothing first. This file sets
#   REPO_ROOT           absolute path of the checkout
#   PROJECT             'wispr-flow-omarchy'
#   LEGACY_PROJECT      'whsprflow-arch' (the upstream this repo derives from)
# and loads versions.env into the environment via load_versions.

PROJECT='wispr-flow-omarchy'
LEGACY_PROJECT='whsprflow-arch'
INSTALL_MARKER=".${PROJECT}-install"
INSTALL_MARKER_VALUE="${PROJECT}-v1"
LEGACY_INSTALL_MARKER=".${LEGACY_PROJECT}-install"
LEGACY_INSTALL_MARKER_VALUE="${LEGACY_PROJECT}-v1"
WRAPPER_TAG='WISPR_FLOW_OMARCHY_WRAPPER=1'
LEGACY_WRAPPER_TAG='WISPR_FLOW_ARCH_WRAPPER=1'
UDEV_RULE_PATH='/usr/lib/udev/rules.d/70-wispr-flow-input.rules'
UDEV_RULE_HEADER='# Wispr Flow Linux helper: injection plus push-to-talk on the active seat.'

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

die() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

warn() {
	printf 'WARNING: %s\n' "$*" >&2
}

info() {
	printf '\n==> %s\n' "$*"
}

have() {
	command -v "$1" >/dev/null 2>&1
}

# Load versions.env and fail loudly if a pin is missing or malformed.
load_versions() {
	local file="${1:-$REPO_ROOT/versions.env}" key
	[[ -f $file ]] || die "Missing $file"
	# Only KEY='value' lines are allowed; refuse anything that could execute code.
	if grep -vE "^([A-Z_][A-Z0-9_]*='[^']*'|#.*|)$" "$file" | grep -q .; then
		die "$file contains a line that is not KEY='value' or a comment."
	fi
	# Export the pins so subshells (PKGBUILD cross-checks, python helpers) see them.
	set -a
	# shellcheck source=/dev/null
	source "$file"
	set +a
	for key in WISPR_FLOW_VERSION WISPR_FLOW_NUPKG_SHA256 WISPR_FLOW_NUPKG_BASE_URL \
		WISPR_FLOW_LATEST_URL ELECTRON_VERSION ELECTRON_LINUX_X64_SHA256 PORT_REPO \
		PORT_COMMIT HELPER_REPO HELPER_COMMIT HELPER_RUSTC_VERSION HELPER_SHA256 \
		SQLITE_RELEASE_BASE_URL SQLITE_NAME SQLITE_SHA256; do
		[[ -n ${!key:-} ]] || die "$file does not define $key"
	done
	[[ $WISPR_FLOW_VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
		|| die "WISPR_FLOW_VERSION is not X.Y.Z: $WISPR_FLOW_VERSION"
	[[ $ELECTRON_VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
		|| die "ELECTRON_VERSION is not X.Y.Z: $ELECTRON_VERSION"
	local sha
	for sha in WISPR_FLOW_NUPKG_SHA256 ELECTRON_LINUX_X64_SHA256 HELPER_SHA256 SQLITE_SHA256; do
		[[ ${!sha} =~ ^[0-9a-f]{64}$ ]] || die "$sha is not a SHA-256 hex digest"
	done
	NUPKG_NAME="WisprFlow-${WISPR_FLOW_VERSION}-full.nupkg"
	NUPKG_URL="${WISPR_FLOW_NUPKG_BASE_URL}/${NUPKG_NAME}"
	ELECTRON_NAME="electron-v${ELECTRON_VERSION}-linux-x64.zip"
	ELECTRON_URL="https://github.com/electron/electron/releases/download/v${ELECTRON_VERSION}/${ELECTRON_NAME}"
	SQLITE_URL="${SQLITE_RELEASE_BASE_URL}/${SQLITE_NAME}"
	export NUPKG_NAME NUPKG_URL ELECTRON_NAME ELECTRON_URL SQLITE_URL
}

sha_ok() {
	local file="$1" expected="$2"
	[[ -f $file ]] && [[ "$(sha256sum "$file" | cut -d' ' -f1)" == "$expected" ]]
}

# Download URL to OUTPUT unless a file with the expected SHA-256 already exists
# there or in one of the extra directories (legacy caches are reused).
download() {
	local url="$1" output="$2" expected="$3" alt
	shift 3
	if sha_ok "$output" "$expected"; then
		printf 'Reusing %s (SHA-256 verified)\n' "$(basename "$output")"
		return
	fi
	for alt in "$@"; do
		if sha_ok "$alt/$(basename "$output")" "$expected"; then
			cp -p "$alt/$(basename "$output")" "$output"
			printf 'Reusing %s from %s (SHA-256 verified)\n' "$(basename "$output")" "$alt"
			return
		fi
	done
	rm -f "$output"
	printf 'Downloading %s\n' "$url"
	curl -fL --retry 3 --output "$output.part" "$url" || die "Download failed: $url"
	mv "$output.part" "$output"
	sha_ok "$output" "$expected" || {
		local actual
		actual="$(sha256sum "$output" | cut -d' ' -f1)"
		rm -f "$output"
		die "SHA-256 mismatch for $(basename "$output"): expected $expected, got $actual"
	}
}

wrapper_owned() {
	local wrapper="$1"
	[[ -f $wrapper ]] && grep -qF -e "$WRAPPER_TAG" -e "$LEGACY_WRAPPER_TAG" "$wrapper"
}

# True when ROOT carries this project's (or the legacy upstream's) ownership marker.
root_marked() {
	local root="$1"
	if [[ -f $root/$INSTALL_MARKER ]] && [[ $(< "$root/$INSTALL_MARKER") == "$INSTALL_MARKER_VALUE" ]]; then
		return 0
	fi
	if [[ -f $root/$LEGACY_INSTALL_MARKER ]] && [[ $(< "$root/$LEGACY_INSTALL_MARKER") == "$LEGACY_INSTALL_MARKER_VALUE" ]]; then
		return 0
	fi
	return 1
}

is_omarchy() {
	[[ -n ${OMARCHY_PATH:-} && -d ${OMARCHY_PATH:-/nonexistent} ]] || [[ -d /usr/share/omarchy ]]
}

omarchy_version() {
	local path="${OMARCHY_PATH:-/usr/share/omarchy}"
	[[ -r $path/version ]] && tr -d '[:space:]' < "$path/version"
}

is_hyprland_session() {
	[[ ${XDG_CURRENT_DESKTOP:-} == *[Hh]yprland* || -n ${HYPRLAND_INSTANCE_SIGNATURE:-} ]]
}
