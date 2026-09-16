#!/usr/bin/env bash
# assemble-app.sh: build the Linux Wispr Flow runtime from verified inputs.
#
# Isolated: no downloads, no sudo, no writes to the real HOME. install.sh and
# the AUR PKGBUILD both call this with inputs they have already verified.

set -Eeuo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
	cat <<'USAGE'
Usage: assemble-app.sh --version VERSION --nupkg FILE --electron-zip FILE \
  --sqlite FILE --helper FILE --port-dir DIR --output-dir DIR \
  [--electron-version VERSION] [--patch-policy strict|tolerant] [--asar-bin COMMAND]

Assembles the patched Linux runtime. Downloads nothing, installs nothing.

  --version VERSION          Wispr Flow version expected inside app.asar.
  --nupkg FILE               Official Wispr Flow Windows nupkg.
  --electron-zip FILE        Official Electron zip for Linux x86_64.
  --electron-version VERSION Expected Electron version (cross-checked against the
                             zip and, when present, the nupkg's Electron).
  --sqlite FILE              node_sqlite3 module for Linux x86_64.
  --helper FILE              Linux helper binary for x86_64.
  --port-dir DIR             Local checkout of the pinned wispr-flow-linux port.
  --output-dir DIR           Output runtime directory; must not exist.
  --patch-policy POLICY      strict (default): every Linux patch must apply.
                             tolerant: optional Hyprland fixes may be skipped;
                             the essential platform patches must still apply.
  --asar-bin COMMAND         asar executable (default: asar).
  -h, --help                 Show this help.
USAGE
}

die() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

usage_error() {
	printf 'ERROR: %s\n' "$*" >&2
	usage >&2
	exit 2
}

info() {
	printf '\n==> %s\n' "$*"
}

set_once() {
	local name="$1" value="$2"
	[[ -z ${!name} ]] || usage_error "$3 was given more than once."
	[[ -n $value ]] || usage_error "$3 needs a value."
	printf -v "$name" '%s' "$value"
}

version=''
nupkg=''
electron_zip=''
electron_version=''
sqlite_bin=''
helper_bin=''
port_dir=''
output_dir=''
patch_policy="${WISPR_FLOW_PATCH_POLICY:-strict}"
asar_bin='asar'
asar_seen=false

while (($#)); do
	case "$1" in
		--version|--nupkg|--electron-zip|--electron-version|--sqlite|--helper|--port-dir|--output-dir|--asar-bin|--patch-policy)
			(($# >= 2)) || usage_error "$1 needs a value."
			flag="$1"
			value="$2"
			case "$flag" in
				--version) set_once version "$value" "$flag" ;;
				--nupkg) set_once nupkg "$value" "$flag" ;;
				--electron-zip) set_once electron_zip "$value" "$flag" ;;
				--electron-version) set_once electron_version "$value" "$flag" ;;
				--sqlite) set_once sqlite_bin "$value" "$flag" ;;
				--helper) set_once helper_bin "$value" "$flag" ;;
				--port-dir) set_once port_dir "$value" "$flag" ;;
				--output-dir) set_once output_dir "$value" "$flag" ;;
				--patch-policy) patch_policy="$value" ;;
				--asar-bin)
					$asar_seen && usage_error "$flag was given more than once."
					[[ -n $value ]] || usage_error "$flag needs a value."
					asar_bin="$value"
					asar_seen=true
					;;
			esac
			shift 2
			;;
		-h|--help)
			usage
			exit 0
			;;
		*) usage_error "Unknown option: $1" ;;
	esac
done

[[ -n $version ]] || usage_error 'Missing --version.'
[[ -n $nupkg ]] || usage_error 'Missing --nupkg.'
[[ -n $electron_zip ]] || usage_error 'Missing --electron-zip.'
[[ -n $sqlite_bin ]] || usage_error 'Missing --sqlite.'
[[ -n $helper_bin ]] || usage_error 'Missing --helper.'
[[ -n $port_dir ]] || usage_error 'Missing --port-dir.'
[[ -n $output_dir ]] || usage_error 'Missing --output-dir.'
[[ $patch_policy == strict || $patch_policy == tolerant ]] \
	|| usage_error '--patch-policy must be strict or tolerant.'

[[ $version =~ ^[0-9]+([.][0-9]+)*([+-][0-9A-Za-z.-]+)?$ ]] \
	|| die "Invalid version: $version"
[[ -z $electron_version || $electron_version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
	|| die "Invalid Electron version: $electron_version"

output_dir="$(realpath -m -- "$output_dir")"
[[ $output_dir == /* && $output_dir != / ]] || die "Unsafe output directory: $output_dir"
[[ ! -e $output_dir && ! -L $output_dir ]] || die "The output directory already exists: $output_dir"
output_parent="$(dirname -- "$output_dir")"
[[ -d $output_parent && -w $output_parent ]] \
	|| die "The parent of the output directory does not exist or is not writable: $output_parent"

for cmd in file grep install node od python3 realpath tr unzip; do
	command -v "$cmd" >/dev/null 2>&1 || die "Missing build dependency '$cmd'."
done
asar_cmd="$(command -v "$asar_bin" 2>/dev/null)" \
	|| die "asar executable not found: $asar_bin"
[[ -x $asar_cmd ]] || die "asar is not executable: $asar_cmd"
asar_cmd="$(realpath -e -- "$asar_cmd")"

canonical_file() {
	local path="$1" label="$2"
	[[ -f $path && -r $path ]] || die "$label is not a readable file: $path"
	realpath -e -- "$path"
}

nupkg="$(canonical_file "$nupkg" 'The nupkg')"
electron_zip="$(canonical_file "$electron_zip" 'The Electron zip')"
sqlite_bin="$(canonical_file "$sqlite_bin" 'The SQLite module')"
helper_bin="$(canonical_file "$helper_bin" 'The helper')"
[[ -d $port_dir && -r $port_dir ]] || die "The port checkout is not a readable directory: $port_dir"
port_dir="$(realpath -e -- "$port_dir")"

patch_dir="$port_dir/scripts/patches"
for port_file in \
	"$patch_dir/helper-resolver.sh" \
	"$patch_dir/helper-env.sh" \
	"$patch_dir/mac-gates.sh" \
	"$patch_dir/linux-window-frame.sh" \
	"$patch_dir/linux-deeplink.sh" \
	"$patch_dir/linux-renderer-chrome.sh" \
	"$patch_dir/linux-renderer-treat-as-windows.sh" \
	"$port_dir/scripts/verify-patches.sh" \
	"$port_dir/scripts/launcher-common.sh" \
	"$port_dir/scripts/doctor.sh"
do
	[[ -f $port_file && -r $port_file ]] || die "Missing required port file: $port_file"
done
for own_file in linux-runtime-fixes.sh helper-env-fallback.sh linux-hub-fixes.sh linux-notetaker-fixes.sh; do
	[[ -f $script_dir/patches/$own_file ]] || die "Missing patches/$own_file."
done
[[ -f $script_dir/assets/UNLICENSE ]] || die 'Missing assets/UNLICENSE.'

unzip -tq "$nupkg" >/dev/null || die 'The nupkg is not a valid zip archive.'
unzip -tq "$electron_zip" >/dev/null || die 'The Electron artifact is not a valid zip archive.'
file "$helper_bin" | grep -q 'ELF 64-bit.*x86-64' \
	|| die 'The helper is not a Linux x86_64 ELF binary.'
file "$sqlite_bin" | grep -q 'ELF 64-bit.*x86-64' \
	|| die 'The SQLite module is not a Linux x86_64 ELF binary.'

work_dir="$(mktemp -d "$output_parent/.assemble-app.XXXXXX")"
cleanup() {
	rm -rf -- "$work_dir"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' HUP TERM

# Keep every subprocess away from the invoking user's real home and caches.
mkdir -p "$work_dir/home" "$work_dir/config" "$work_dir/cache" \
	"$work_dir/nupkg" "$work_dir/app" "$work_dir/runtime"
export HOME="$work_dir/home"
export XDG_CONFIG_HOME="$work_dir/config"
export XDG_CACHE_HOME="$work_dir/cache"
export WISPR_FLOW_PATCH_POLICY="$patch_policy"

"$asar_cmd" --version >/dev/null || die "Could not run asar: $asar_cmd"

info 'Extracting the official client and Electron for Linux'
unzip -q "$nupkg" -d "$work_dir/nupkg"
unzip -q "$electron_zip" -d "$work_dir/runtime"

resources_src="$work_dir/nupkg/lib/net45/resources"
[[ -f $resources_src/app.asar ]] || die 'The nupkg does not contain resources/app.asar.'
for resource_dir in assets migrations; do
	[[ -d $resources_src/$resource_dir ]] \
		|| die "The nupkg does not contain resources/$resource_dir."
done
for electron_file in electron chrome-sandbox icudtl.dat resources.pak version; do
	[[ -f $work_dir/runtime/$electron_file ]] \
		|| die "The Electron zip does not contain $electron_file."
done

info 'Unpacking and adapting the client to Linux'
"$asar_cmd" extract "$resources_src/app.asar" "$work_dir/app"

[[ -f $work_dir/app/package.json ]] || die 'app.asar does not contain package.json.'
actual_version="$(node -e 'process.stdout.write(require(process.argv[1]).version)' \
	"$work_dir/app/package.json")"
[[ $actual_version == "$version" ]] \
	|| die "Unexpected version inside app.asar: $actual_version (expected $version)"

main_bundle="$work_dir/app/.webpack/main/index.js"
hub_renderer="$work_dir/app/.webpack/renderer/hub/index.js"
[[ -f $main_bundle ]] || die 'app.asar does not contain the expected main bundle.'
[[ -f $hub_renderer ]] || die 'app.asar does not contain the expected Flow Hub renderer.'

# Electron version cross-check: the Linux runtime must match the Electron the
# Windows client was built for, otherwise the SQLite native module's ABI is wrong.
# The client's Electron comes from the Squirrel `version` file when the nupkg
# carries one (older releases) and otherwise from the app's own package.json.
linux_electron="$(tr -d '[:space:]' < "$work_dir/runtime/version")"
linux_electron="${linux_electron#v}"
if [[ -n $electron_version && $linux_electron != "$electron_version" ]]; then
	die "The Electron zip is v$linux_electron but --electron-version says $electron_version."
fi
windows_electron=''
if [[ -f $work_dir/nupkg/lib/net45/version ]]; then
	windows_electron="$(tr -d '[:space:]' < "$work_dir/nupkg/lib/net45/version")"
	windows_electron="${windows_electron#v}"
fi
if [[ ! $windows_electron =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
	windows_electron="$(node -e 'process.stdout.write(String(require(process.argv[1]).devDependencies?.electron ?? ""))' \
		"$work_dir/app/package.json" 2>/dev/null || true)"
	windows_electron="${windows_electron#^}"
fi
if [[ $windows_electron =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
	if [[ $windows_electron != "$linux_electron" ]]; then
		if [[ ${windows_electron%%.*} != "${linux_electron%%.*}" ]]; then
			die "Electron major mismatch: the Windows client ships Electron $windows_electron, the Linux runtime is $linux_electron. Update ELECTRON_VERSION (scripts/pin-latest.sh) and rebuild the SQLite module for the new ABI."
		fi
		printf 'WARNING: Electron %s (Windows client) vs %s (Linux runtime); same major, continuing.\n' \
			"$windows_electron" "$linux_electron" >&2
	else
		printf 'Electron %s matches between the Windows client and the Linux runtime.\n' "$linux_electron"
	fi
else
	windows_electron=''
	printf 'NOTE: could not read the Electron version of the Windows client; skipping the cross-check.\n'
fi

report="$work_dir/patch-report.txt"
: > "$report"
note() {
	printf '%s\n' "$*" >> "$report"
}

# --- Essential platform patches (always required) ---------------------------
bash "$patch_dir/helper-resolver.sh" "$main_bundle" && note 'APPLIED port/helper-resolver'
if bash "$patch_dir/helper-env.sh" "$main_bundle"; then
	note 'APPLIED port/helper-env'
else
	# Wispr >= 1.6.774 factored the helper env into a function; the upstream
	# anchor `env:{` is gone. Apply the nucleus-anchored fallback instead.
	bash "$script_dir/patches/helper-env-fallback.sh" "$main_bundle" && note 'APPLIED helper-env-fallback'
fi
bash "$patch_dir/mac-gates.sh" "$main_bundle" && note 'APPLIED port/mac-gates'
bash "$patch_dir/linux-deeplink.sh" "$main_bundle" && note 'APPLIED port/linux-deeplink'
bash "$patch_dir/linux-renderer-chrome.sh" "$hub_renderer" && note 'APPLIED port/linux-renderer-chrome'

renderer_count=0
for renderer in "$work_dir"/app/.webpack/renderer/*/index.js; do
	[[ -f $renderer ]] || continue
	grep -qF 'platform?.isWindows' "$renderer" || continue
	bash "$patch_dir/linux-renderer-treat-as-windows.sh" "$renderer"
	renderer_count=$((renderer_count + 1))
done
((renderer_count > 0)) || die 'No renderer was adapted to Linux.'
note "APPLIED port/linux-renderer-treat-as-windows ($renderer_count renderers)"

# --- Optional fixes (policy-controlled) --------------------------------------
if bash "$patch_dir/linux-window-frame.sh" "$main_bundle"; then
	note 'APPLIED port/linux-window-frame'
elif [[ $patch_policy == tolerant ]]; then
	note 'SKIPPED port/linux-window-frame: anchor not found (meeting recorder window keeps a native title bar)'
	printf 'WARNING: linux-window-frame skipped under the tolerant policy.\n' >&2
else
	die 'linux-window-frame did not apply. Re-audit or use --patch-policy tolerant.'
fi

bash "$script_dir/patches/linux-hub-fixes.sh" "$main_bundle" --policy "$patch_policy" --report "$report"
bash "$script_dir/patches/linux-runtime-fixes.sh" "$main_bundle" --policy "$patch_policy" --report "$report"
bash "$script_dir/patches/linux-notetaker-fixes.sh" "$main_bundle" --policy "$patch_policy" --report "$report"

# Patch scripts intentionally create backups. Never ship them in the asar.
shopt -s globstar nullglob dotglob
rm -f "$work_dir"/app/**/*.orig "$work_dir"/app/**/*.macgate.orig
shopt -u globstar nullglob dotglob

native_dir="$work_dir/app/.webpack/main/native_modules/build/Release"
mkdir -p "$native_dir"
install -m 0755 "$sqlite_bin" "$native_dir/node_sqlite3.node"
[[ $(od -An -N4 -tx1 "$native_dir/node_sqlite3.node" | tr -d ' \n') == 7f454c46 ]] \
	|| die 'The SQLite module lost its ELF header.'

node --check "$main_bundle"
for renderer in "$work_dir"/app/.webpack/renderer/*/index.js; do
	[[ -f $renderer ]] && node --check "$renderer"
done

# Record which product surfaces this bundle carries, so the doctor and the
# documentation describe the build that was actually installed.
features="$work_dir/features"
{
	renderers=()
	for renderer in "$work_dir"/app/.webpack/renderer/*/index.js; do
		[[ -f $renderer ]] && renderers+=("$(basename "$(dirname "$renderer")")")
	done
	printf 'wispr-flow=%s\n' "$version"
	printf 'electron=%s\n' "$linux_electron"
	printf 'client-electron=%s\n' "${windows_electron:-unknown}"
	printf 'renderers=%s\n' "$(IFS=,; printf '%s' "${renderers[*]}")"
	if grep -qi 'notetaker' "$main_bundle" || [[ -d $work_dir/app/.webpack/renderer/meeting_recorder ]]; then
		printf 'notetaker-ui=yes\n'
	else
		printf 'notetaker-ui=no\n'
	fi
	printf 'patch-policy=%s\n' "$patch_policy"
} > "$features"

resources_dst="$work_dir/runtime/resources"
mkdir -p "$resources_dst/Release"
cp -a "$resources_src/assets" "$resources_dst/assets"
cp -a "$resources_src/migrations" "$resources_dst/migrations"
for extra in ax-inspect-lib.mjs ax-inspect-server.mjs ax-inspect.mjs; do
	[[ -f $resources_src/$extra ]] && cp "$resources_src/$extra" "$resources_dst/$extra"
done

rm -f "$work_dir/app/.webpack/main/native_modules/lib"/crypt32-*.node
"$asar_cmd" pack "$work_dir/app" "$resources_dst/app.asar" --unpack '*.node'
install -m 0755 "$sqlite_bin" \
	"$resources_dst/app.asar.unpacked/.webpack/main/native_modules/build/Release/node_sqlite3.node"
"$asar_cmd" list "$resources_dst/app.asar" > "$work_dir/asar-files.txt"
if grep -q 'crypt32-' "$work_dir/asar-files.txt"; then
	die 'The final asar still references Windows-only crypt32 modules.'
fi
if grep -q '\.orig$' "$work_dir/asar-files.txt"; then
	die 'The final asar still contains patch backups.'
fi

install -m 0755 "$helper_bin" "$resources_dst/Release/wispr-flow-linux-helper"
install -m 0644 "$script_dir/assets/UNLICENSE" "$resources_dst/Release/helper.UNLICENSE"

# Marker verification over the packed asar: the essential markers always, the
# optional ones only under the strict policy (the report records the rest).
verify_markers() {
	local label pattern missing=0
	while IFS='|' read -r label pattern; do
		[[ -n $label ]] || continue
		if grep -aqF -- "$pattern" "$resources_dst/app.asar"; then
			printf '  OK      %s\n' "$label"
		else
			printf '  MISSING %s\n' "$label" >&2
			missing=1
		fi
	done
	return "$missing"
}
info 'Verifying Linux patch markers in the packed asar'
essential_markers='helper resolver|WISPR_LINUX_HELPER_BRANCH
helper env spread|WISPR_LINUX_HELPER_ENV
linux helper path|wispr-flow-linux-helper
deep link on cold start|WISPR_LINUX_DEEPLINK
renderer chrome remap|WISPR_LINUX_WIN32_CHROME
renderer isWindows widen|WISPR_LINUX_RENDERER_ISWIN'
verify_markers <<< "$essential_markers" || die 'Essential Linux patch markers are missing from app.asar.'
grep -aqP 'if\("darwin"!==process\.platform\)return!1;const[ ]*[\w$]+=[\w$]+\.app\.getAppPath' \
	"$resources_dst/app.asar" || die 'The macOS Applications-folder gate is missing from app.asar.'
if [[ $patch_policy == strict ]]; then
	bash "$port_dir/scripts/verify-patches.sh" "$resources_dst/app.asar"
	optional_markers='hub warm deep link|WISPR_LINUX_WARM_DEEPLINK
hub focusable|WISPR_LINUX_HUB_FOCUSABLE
singleton exit|WISPR_LINUX_SINGLETON_EXIT
status show guard|WISPR_LINUX_HIDE_STATUS_WINDOW_SHOW
status dictation guard|WISPR_LINUX_HIDE_STATUS_WINDOW_DICTATION
status transient show|WISPR_LINUX_TRANSIENT_STATUS_SHOW
local start sound|WISPR_LINUX_LOCAL_START_SOUND
local stop sound|WISPR_LINUX_LOCAL_STOP_SOUND
status bounds|WISPR_LINUX_COMPACT_STATUS_WINDOW
status transient hide|WISPR_LINUX_TRANSIENT_STATUS_HIDE
status zoom|WISPR_LINUX_STATUS_ZOOM
status geometry|WISPR_LINUX_STATUS_GEOMETRY
status position|WISPR_LINUX_STATUS_POSITION
status interactive|WISPR_LINUX_STATUS_INTERACTIVE
status interactive ipc|WISPR_LINUX_STATUS_IPC
status hit test|WISPR_LINUX_STATUS_HITTEST
status tour|WISPR_LINUX_STATUS_TOUR'
	# The Notetaker fix only applies to bundles that carry the meeting recorder.
	if grep -qE '^(APPLIED|ALREADY) linux-notetaker-fixes/display-media' "$report"; then
		optional_markers+='
notetaker loopback gate|WISPR_LINUX_NOTETAKER_LOOPBACK_GATE
notetaker loopback branch|WISPR_LINUX_NOTETAKER_LOOPBACK_BRANCH'
	fi
	verify_markers <<< "$optional_markers" || die 'Optional Linux patch markers are missing from app.asar under the strict policy.'
fi

mv "$work_dir/runtime/electron" "$work_dir/runtime/wispr-flow"
chmod 0755 "$work_dir/runtime/wispr-flow"
install -m 0644 "$port_dir/scripts/launcher-common.sh" "$work_dir/runtime/launcher-common.sh"
install -m 0644 "$port_dir/scripts/doctor.sh" "$work_dir/runtime/doctor.sh"
install -m 0644 "$report" "$work_dir/runtime/patch-report.txt"
install -m 0644 "$features" "$work_dir/runtime/features"
printf '%s\n' "$version" > "$work_dir/runtime/app-version"

info 'Verifying the assembled runtime'
for runtime_file in \
	"$work_dir/runtime/wispr-flow" \
	"$work_dir/runtime/chrome-sandbox" \
	"$resources_dst/app.asar" \
	"$resources_dst/app.asar.unpacked/.webpack/main/native_modules/build/Release/node_sqlite3.node" \
	"$resources_dst/Release/wispr-flow-linux-helper" \
	"$resources_dst/Release/helper.UNLICENSE" \
	"$work_dir/runtime/launcher-common.sh" \
	"$work_dir/runtime/doctor.sh" \
	"$work_dir/runtime/patch-report.txt" \
	"$work_dir/runtime/features" \
	"$work_dir/runtime/app-version"
do
	[[ -f $runtime_file ]] || die "The final runtime is incomplete: $runtime_file"
done
[[ -x $work_dir/runtime/wispr-flow ]] || die 'The final Electron binary is not executable.'
[[ -x $resources_dst/Release/wispr-flow-linux-helper ]] || die 'The final helper is not executable.'
[[ ! -e $work_dir/runtime/electron ]] || die 'The Electron binary was not renamed.'
[[ $(< "$work_dir/runtime/app-version") == "$version" ]] || die 'app-version is wrong.'
cmp -s "$sqlite_bin" \
	"$resources_dst/app.asar.unpacked/.webpack/main/native_modules/build/Release/node_sqlite3.node" \
	|| die 'The final SQLite module does not match the verified input.'
cmp -s "$helper_bin" "$resources_dst/Release/wispr-flow-linux-helper" \
	|| die 'The final helper does not match the verified input.'
cmp -s "$script_dir/assets/UNLICENSE" "$resources_dst/Release/helper.UNLICENSE" \
	|| die 'The final helper license is wrong.'

# The work directory is on the output filesystem, so this rename publishes the
# verified runtime atomically and leaves no partial output on error.
mv -- "$work_dir/runtime" "$output_dir"
printf '\nRuntime assembled: %s\n' "$output_dir"
if grep -q '^SKIPPED' "$output_dir/patch-report.txt"; then
	printf 'Optional fixes skipped (tolerant policy):\n'
	grep '^SKIPPED' "$output_dir/patch-report.txt" | sed 's/^/  /'
fi
