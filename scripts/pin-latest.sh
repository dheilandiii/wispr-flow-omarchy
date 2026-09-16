#!/usr/bin/env bash
# pin-latest.sh: move versions.env to a newer Wispr Flow Windows release.
#
# Resolves the current release from Wispr's Squirrel RELEASES feed (the file
# the Windows client polls; the installer redirect is the fallback), or takes
# an explicit version / local nupkg, downloads and hashes the nupkg, reads the
# Electron version the client was built with, fetches the matching Linux
# Electron hash from GitHub, audits every Linux patch against the new bundle,
# and, with --write, rewrites the pins. Without --write it only reports.
#
# Usage: pin-latest.sh [--version X.Y.Z | --nupkg FILE] [--write]
#                      [--allow-electron-change] [--force]
#   --version X.Y.Z          pin this release instead of the latest one
#   --nupkg FILE             use a local nupkg (offline; version from its name)
#   --write                  update versions.env after a successful audit
#   --allow-electron-change  accept an Electron major bump (the SQLite module
#                            must then be rebuilt for the new ABI first)
#   --force                  re-audit even when the version is already pinned
#
# Run this on the machine that installs Wispr Flow: dl.wisprflow.com is not
# reachable from every network.

set -Eeuo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$script_dir/scripts/lib/common.sh"
load_versions

requested=''
local_nupkg=''
write=false
allow_electron_change=false
force=false
while (($#)); do
	case "$1" in
		--version) requested="${2:-}"; shift ;;
		--nupkg) local_nupkg="${2:-}"; shift ;;
		--write) write=true ;;
		--allow-electron-change) allow_electron_change=true ;;
		--force) force=true ;;
		-h|--help) sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
		*) printf 'Unknown option: %s\n' "$1" >&2; exit 2 ;;
	esac
	shift
done
[[ -z $requested || $requested =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "--version must be X.Y.Z, got $requested"
[[ -z $requested || -z $local_nupkg ]] || die 'Give only one of --version and --nupkg.'

for cmd in curl sha256sum unzip; do
	have "$cmd" || die "Missing '$cmd'."
done
releases_url="${WISPR_FLOW_NUPKG_BASE_URL}/RELEASES"
releases_feed=''

# Print the "SHA1 name size" lines of Squirrel's RELEASES feed (BOM and CR stripped).
releases_entries() {
	printf '%s\n' "$releases_feed" | tr -d '\r' | sed 's/^\xEF\xBB\xBF//' \
		| sed -nE 's/^([0-9A-Fa-f]{40}) (WisprFlow-[0-9]+\.[0-9]+\.[0-9]+-full\.nupkg) ([0-9]+)$/\1 \2 \3/p'
}

cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/$PROJECT"
mkdir -p "$cache_dir"

# --- 1. Which version? ------------------------------------------------------
if [[ -n $local_nupkg ]]; then
	[[ -f $local_nupkg ]] || die "nupkg not found: $local_nupkg"
	name="$(basename "$local_nupkg")"
	[[ $name =~ ^WisprFlow-([0-9]+\.[0-9]+\.[0-9]+)-full\.nupkg$ ]] \
		|| die "Cannot read a version from the file name $name (expected WisprFlow-X.Y.Z-full.nupkg)."
	new_version="${BASH_REMATCH[1]}"
elif [[ -n $requested ]]; then
	new_version="$requested"
else
	info "Resolving the latest Windows release from $releases_url"
	new_version=''
	if releases_feed="$(curl -fsSL --max-time 60 "$releases_url")"; then
		# The feed lists every full nupkg Squirrel may serve; the newest wins.
		new_version="$(releases_entries | sed -nE 's/^[0-9A-Fa-f]{40} WisprFlow-([0-9]+\.[0-9]+\.[0-9]+)-full\.nupkg [0-9]+$/\1/p' \
			| sort -t. -k1,1n -k2,2n -k3,3n | tail -n1)"
	else
		releases_feed=''
		warn "Could not fetch $releases_url; falling back to the installer redirect."
	fi
	if [[ -z $new_version ]]; then
		final_url="$(curl -fsSLI -o /dev/null -w '%{url_effective}' --max-time 60 "$WISPR_FLOW_LATEST_URL")" \
			|| die "Could not resolve $WISPR_FLOW_LATEST_URL (is dl.wisprflow.ai reachable from this network?)."
		[[ $final_url != "$WISPR_FLOW_LATEST_URL" ]] || die 'The latest URL did not redirect anywhere.'
		new_version="$(printf '%s\n' "$final_url" | sed -nE 's/.*(WisprFlow[-_]|[Ss]etup-v)([0-9]+\.[0-9]+\.[0-9]+).*\.exe.*/\2/p')"
		[[ -n $new_version ]] || die "Could not parse a version from $final_url (the installer name carries no version; pass --version X.Y.Z)."
	fi
	printf 'Latest Windows release: %s\n' "$new_version"
fi

if [[ $new_version == "$WISPR_FLOW_VERSION" ]] && ! $force; then
	printf 'versions.env already pins Wispr Flow %s. Use --force to re-audit it.\n' "$new_version"
	exit 0
fi

# --- 2. Download and hash the nupkg -----------------------------------------
new_nupkg_name="WisprFlow-${new_version}-full.nupkg"
new_nupkg_url="${WISPR_FLOW_NUPKG_BASE_URL}/${new_nupkg_name}"
nupkg_path="$cache_dir/$new_nupkg_name"
if [[ -n $local_nupkg ]]; then
	cp -p "$local_nupkg" "$nupkg_path"
elif [[ ! -f $nupkg_path ]]; then
	info "Downloading $new_nupkg_url"
	curl -fL --retry 3 --output "$nupkg_path.part" "$new_nupkg_url" || die "Download failed: $new_nupkg_url"
	mv "$nupkg_path.part" "$nupkg_path"
else
	printf 'Reusing cached %s\n' "$nupkg_path"
fi
unzip -tq "$nupkg_path" >/dev/null || die 'The nupkg is not a valid zip archive.'
new_nupkg_sha="$(sha256sum "$nupkg_path" | cut -d' ' -f1)"
printf 'nupkg SHA-256: %s\n' "$new_nupkg_sha"
# Squirrel publishes a SHA-1 per nupkg; cross-check it when the feed is at hand.
if [[ -n $releases_feed ]] && have sha1sum; then
	feed_sha1="$(releases_entries | awk -v name="$new_nupkg_name" '$2 == name { print tolower($1) }' | head -n1)"
	if [[ -n $feed_sha1 ]]; then
		[[ $(sha1sum "$nupkg_path" | cut -d' ' -f1) == "$feed_sha1" ]] \
			|| die "The nupkg does not match the SHA-1 published in $releases_url; refusing to pin a corrupt download."
		printf 'nupkg SHA-1 matches the RELEASES feed.\n'
	fi
fi

# --- 3. Electron version inside the Windows client ---------------------------
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
new_electron="$ELECTRON_VERSION"
new_electron_sha="$ELECTRON_LINUX_X64_SHA256"
windows_electron="$(nupkg_electron_version "$nupkg_path")"
if [[ -n $windows_electron ]]; then
	printf 'Electron in the Windows client: %s (pinned Linux runtime: %s)\n' "$windows_electron" "$ELECTRON_VERSION"
	if [[ $windows_electron != "$ELECTRON_VERSION" ]]; then
		if [[ ${windows_electron%%.*} != "${ELECTRON_VERSION%%.*}" ]]; then
			cat <<BLOCKER

BLOCKER: the Electron major changed ($ELECTRON_VERSION -> $windows_electron).
The pinned node_sqlite3 module is compiled for Electron ${ELECTRON_VERSION%%.*}'s ABI and
will not load under Electron ${windows_electron%%.*}. Before pinning this release:
  1. rebuild node_sqlite3 for Electron $windows_electron (see the wispr-flow-linux
     native-modules repository and scripts/rebuild-native-modules.sh in the port),
  2. publish/host it and update SQLITE_RELEASE_BASE_URL / SQLITE_SHA256,
  3. re-run this script with --allow-electron-change.
BLOCKER
			$allow_electron_change || exit 1
		fi
		sums_url="https://github.com/electron/electron/releases/download/v${windows_electron}/SHASUMS256.txt"
		info "Fetching Electron $windows_electron checksums"
		curl -fsSL --retry 3 -o "$work/SHASUMS256.txt" "$sums_url" || die "Could not fetch $sums_url"
		new_electron_sha="$(awk -v name="electron-v${windows_electron}-linux-x64.zip" '$2 == "*" name || $2 == name { print $1 }' "$work/SHASUMS256.txt")"
		[[ $new_electron_sha =~ ^[0-9a-f]{64}$ ]] || die "No linux-x64 checksum for Electron $windows_electron in SHASUMS256.txt"
		new_electron="$windows_electron"
		printf 'Electron %s linux-x64 SHA-256: %s\n' "$new_electron" "$new_electron_sha"
	fi
else
	warn 'Could not read the Electron version of the Windows client; keeping the pinned Electron version.'
fi

# --- 4. Audit every Linux patch against the new bundle -----------------------
info "Auditing the Linux patches against Wispr Flow $new_version"
audit_rc=0
"$script_dir/scripts/audit-bundle.sh" --nupkg "$nupkg_path" || audit_rc=$?
if ((audit_rc != 0)); then
	printf '\nThe audit found essential failures; versions.env was not changed.\n'
	exit 1
fi

# --- 5. Write --------------------------------------------------------------
if ! $write; then
	cat <<REPORT

Dry run. To pin Wispr Flow $new_version run:
  scripts/pin-latest.sh --version $new_version --write
Then: tests/smoke.sh, ./install.sh, update packaging/aur/PKGBUILD and CHANGELOG.md, commit.
REPORT
	exit 0
fi

versions_file="$script_dir/versions.env"
python3 - "$versions_file" "$new_version" "$new_nupkg_sha" "$new_electron" "$new_electron_sha" <<'PY'
import pathlib, re, sys
path = pathlib.Path(sys.argv[1])
version, nupkg_sha, electron, electron_sha = sys.argv[2:6]
text = path.read_text()
def set_key(text, key, value):
    pattern = re.compile(rf"^{key}='[^']*'$", re.M)
    if len(pattern.findall(text)) != 1:
        sys.exit(f"ERROR: expected exactly one {key} line in versions.env")
    return pattern.sub(f"{key}='{value}'", text)
text = set_key(text, "WISPR_FLOW_VERSION", version)
text = set_key(text, "WISPR_FLOW_NUPKG_SHA256", nupkg_sha)
text = set_key(text, "ELECTRON_VERSION", electron)
text = set_key(text, "ELECTRON_LINUX_X64_SHA256", electron_sha)
path.write_text(text)
print(f"versions.env now pins Wispr Flow {version} (Electron {electron}).")
PY

cat <<NEXT

Next:
  tests/smoke.sh                       (checks the pins and the scripts)
  ./install.sh                         (or with --patch-policy tolerant if optional fixes were skipped)
  packaging/aur/PKGBUILD               update pkgver, sources and sha256sums to match versions.env
  CHANGELOG.md                         record the bump
NEXT
