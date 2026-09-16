#!/usr/bin/env bash
# audit-bundle.sh: dry-run every Linux patch against a Wispr Flow bundle and
# report which anchors still match. Run it before pinning a new release.
#
# Nothing is installed and the inputs are not modified: the app is extracted to
# a temporary directory, patched there under the tolerant policy, and the
# result is summarised as ESSENTIAL / OPTIONAL rows.
#
# Usage: audit-bundle.sh (--nupkg FILE | --app-dir DIR) [--port-dir DIR]
#                        [--strict] [--keep DIR]
#   --nupkg FILE     official WisprFlow-<version>-full.nupkg
#   --app-dir DIR    an already extracted app.asar directory
#   --port-dir DIR   wispr-flow-linux checkout (default: $WISPR_FLOW_PORT_DIR, else
#                    the pinned commit cloned into the cache)
#   --strict         exit non-zero when an OPTIONAL patch fails too
#   --keep DIR       keep the patched app tree at DIR for inspection
# Exit 0 when every essential patch applies (and, with --strict, every optional
# one), 1 otherwise, 2 on usage errors.

set -Eeuo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$script_dir/scripts/lib/common.sh"
load_versions

nupkg=''
app_dir=''
port_dir=''
strict=false
keep=''
while (($#)); do
	case "$1" in
		--nupkg) nupkg="${2:-}"; shift ;;
		--app-dir) app_dir="${2:-}"; shift ;;
		--port-dir) port_dir="${2:-}"; shift ;;
		--strict) strict=true ;;
		--keep) keep="${2:-}"; shift ;;
		-h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
		*) printf 'Unknown option: %s\n' "$1" >&2; exit 2 ;;
	esac
	shift
done
[[ -n $nupkg || -n $app_dir ]] || { printf 'Give --nupkg FILE or --app-dir DIR.\n' >&2; exit 2; }
[[ -z $nupkg || -z $app_dir ]] || { printf 'Give only one of --nupkg and --app-dir.\n' >&2; exit 2; }

for cmd in node python3 unzip; do
	have "$cmd" || die "Missing '$cmd'."
done

asar_cmd=''
if have asar; then
	asar_cmd='asar'
elif have npx; then
	asar_cmd='npx --yes @electron/asar'
	printf 'NOTE: using @electron/asar via npx (install the asar package to avoid the download).\n' >&2
elif [[ -n $nupkg ]]; then
	die "Missing 'asar' (Arch package: asar)."
fi

ensure_port_dir() {
	[[ -n $port_dir ]] || port_dir="${WISPR_FLOW_PORT_DIR:-}"
	[[ -n $port_dir ]] && { port_dir="$(realpath -e -- "$port_dir")"; return; }
	local cache="${XDG_CACHE_HOME:-$HOME/.cache}/$PROJECT/port-$PORT_COMMIT"
	if [[ ! -d $cache/.git ]]; then
		have git || die "Missing 'git' to fetch the pinned port."
		mkdir -p "$(dirname "$cache")"
		rm -rf "$cache"
		git clone --quiet --no-checkout "$PORT_REPO" "$cache"
		git -C "$cache" checkout --quiet "$PORT_COMMIT"
	fi
	[[ $(git -C "$cache" rev-parse HEAD) == "$PORT_COMMIT" ]] || die 'The cached port checkout does not match the pinned commit.'
	port_dir="$cache"
}
ensure_port_dir

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

electron_windows=''
if [[ -n $nupkg ]]; then
	[[ -f $nupkg ]] || die "nupkg not found: $nupkg"
	unzip -tq "$nupkg" >/dev/null || die 'The nupkg is not a valid zip archive.'
	info "Extracting $(basename "$nupkg")"
	mkdir -p "$work/nupkg"
	unzip -q "$nupkg" -d "$work/nupkg"
	[[ -f $work/nupkg/lib/net45/resources/app.asar ]] || die 'The nupkg does not contain resources/app.asar.'
	[[ -f $work/nupkg/lib/net45/version ]] && electron_windows="$(tr -d '[:space:]' < "$work/nupkg/lib/net45/version")"
	$asar_cmd extract "$work/nupkg/lib/net45/resources/app.asar" "$work/app"
	app_dir="$work/app"
else
	[[ -d $app_dir ]] || die "app dir not found: $app_dir"
	mkdir -p "$work/app"
	cp -a "$app_dir/." "$work/app/"
	app_dir="$work/app"
fi

main_bundle="$app_dir/.webpack/main/index.js"
hub_renderer="$app_dir/.webpack/renderer/hub/index.js"
[[ -f $main_bundle ]] || die 'No .webpack/main/index.js in the app directory.'
[[ -f $hub_renderer ]] || die 'No .webpack/renderer/hub/index.js in the app directory.'
version="$(node -e 'process.stdout.write(require(process.argv[1]).version)' "$app_dir/package.json" 2>/dev/null || echo unknown)"
if [[ ! $electron_windows =~ ^v?[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
	# Current releases carry no Squirrel version file; the app's package.json
	# names the Electron it was built with.
	electron_windows="$(node -e 'process.stdout.write(String(require(process.argv[1]).devDependencies?.electron ?? ""))' "$app_dir/package.json" 2>/dev/null || true)"
fi
electron_windows="${electron_windows#v}"

printf '\nWispr Flow bundle audit\n=======================\n'
printf 'Version:            %s (pinned: %s)\n' "$version" "$WISPR_FLOW_VERSION"
printf 'Electron (Windows): %s (pinned Linux runtime: %s)\n' "${electron_windows:-unknown}" "$ELECTRON_VERSION"
renderers=()
for renderer in "$app_dir"/.webpack/renderer/*/index.js; do
	renderers+=("$(basename "$(dirname "$renderer")")")
done
printf 'Renderers:          %s\n' "${renderers[*]}"
if grep -qi 'notetaker' "$main_bundle" || [[ -d $app_dir/.webpack/renderer/meeting_recorder ]]; then
	printf 'Notetaker UI:       present in this bundle\n'
else
	printf 'Notetaker UI:       not found in this bundle\n'
fi

patch_dir="$port_dir/scripts/patches"
report="$work/report.txt"
: > "$report"
essential_failed=0
optional_failed=0

row() {
	printf '  %-9s %-40s %s\n' "$1" "$2" "$3"
}

run_patch() {
	# run_patch TIER NAME COMMAND...
	local tier="$1" name="$2"
	shift 2
	local out
	if out="$("$@" 2>&1)"; then
		row "$tier" "$name" 'OK'
	else
		row "$tier" "$name" 'FAILED'
		printf '%s\n' "$out" | tail -n 3 | sed 's/^/            /'
		if [[ $tier == ESSENTIAL ]]; then
			essential_failed=$((essential_failed + 1))
		else
			optional_failed=$((optional_failed + 1))
		fi
	fi
}

printf '\nPatch anchors\n'
run_patch ESSENTIAL 'port/helper-resolver' bash "$patch_dir/helper-resolver.sh" "$main_bundle"
if bash "$patch_dir/helper-env.sh" "$main_bundle" >/dev/null 2>&1; then
	row ESSENTIAL 'port/helper-env' 'OK'
else
	run_patch ESSENTIAL 'helper-env-fallback (>= 1.6.774 shape)' bash "$script_dir/patches/helper-env-fallback.sh" "$main_bundle"
fi
run_patch ESSENTIAL 'port/mac-gates' bash "$patch_dir/mac-gates.sh" "$main_bundle"
run_patch ESSENTIAL 'port/linux-deeplink' bash "$patch_dir/linux-deeplink.sh" "$main_bundle"
run_patch ESSENTIAL 'port/linux-renderer-chrome' bash "$patch_dir/linux-renderer-chrome.sh" "$hub_renderer"
renderer_count=0
for renderer in "$app_dir"/.webpack/renderer/*/index.js; do
	grep -qF 'platform?.isWindows' "$renderer" || continue
	if bash "$patch_dir/linux-renderer-treat-as-windows.sh" "$renderer" >/dev/null 2>&1; then
		renderer_count=$((renderer_count + 1))
	else
		row ESSENTIAL "port/treat-as-windows ($(basename "$(dirname "$renderer")"))" 'FAILED'
		essential_failed=$((essential_failed + 1))
	fi
done
if ((renderer_count > 0)); then
	row ESSENTIAL "port/linux-renderer-treat-as-windows" "OK ($renderer_count renderers)"
else
	row ESSENTIAL "port/linux-renderer-treat-as-windows" 'FAILED (no renderer reads isWindows)'
	essential_failed=$((essential_failed + 1))
fi
run_patch OPTIONAL 'port/linux-window-frame' bash "$patch_dir/linux-window-frame.sh" "$main_bundle"

bash "$script_dir/patches/linux-hub-fixes.sh" "$main_bundle" --policy tolerant --report "$report" >/dev/null 2>&1 || true
bash "$script_dir/patches/linux-runtime-fixes.sh" "$main_bundle" --policy tolerant --report "$report" >/dev/null 2>&1 || true
bash "$script_dir/patches/linux-notetaker-fixes.sh" "$main_bundle" --hub "$hub_renderer" --policy tolerant --report "$report" >/dev/null 2>&1 || true
while IFS= read -r line; do
	status="${line%% *}"
	rest="${line#* }"
	name="${rest%%:*}"
	detail=''
	[[ $rest == *:* ]] && detail="${rest#*: }"
	case "$status" in
		APPLIED|ALREADY) row OPTIONAL "$name" 'OK' ;;
		ABSENT) row OPTIONAL "$name" "n/a ($detail)" ;;
		SKIPPED) row OPTIONAL "$name" "FAILED ($detail)"; optional_failed=$((optional_failed + 1)) ;;
	esac
done < "$report"

if node --check "$main_bundle" >/dev/null 2>&1; then
	row CHECK 'node --check main bundle' 'OK'
else
	row CHECK 'node --check main bundle' 'FAILED'
	essential_failed=$((essential_failed + 1))
fi

if [[ -n $keep ]]; then
	rm -rf "$keep"
	cp -a "$app_dir" "$keep"
	printf '\nPatched app tree kept at %s\n' "$keep"
fi

printf '\nSummary: %s essential failure(s), %s optional failure(s)\n' "$essential_failed" "$optional_failed"
if ((essential_failed > 0)); then
	printf 'This release cannot be built until the essential patches are re-audited.\n'
	exit 1
fi
if ((optional_failed > 0)); then
	if $strict; then
		printf 'Optional fixes need re-auditing (strict audit requested).\n'
		exit 1
	fi
	printf 'Build works with WISPR_FLOW_PATCH_POLICY=tolerant; re-audit the optional fixes to restore the strict default.\n'
fi
exit 0
