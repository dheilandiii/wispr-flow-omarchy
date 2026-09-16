#!/usr/bin/env bash
# smoke.sh: offline verification of the wispr-flow-omarchy support code.
#
# Covers script syntax, the pins (versions.env against the PKGBUILD, the helper
# asset and the patch files), the per-user configurer in all three Hyprland
# modes, the launcher's backend and Notetaker decisions, every Linux patch
# script against synthetic bundles, and, when a wispr-flow-linux checkout is
# available (WISPR_FLOW_PORT_DIR, the install cache, or a fresh clone), the
# assembler end to end. No proprietary file is needed and nothing is installed.

set -Eeuo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export TMPDIR="$tmp"

# shellcheck source=scripts/lib/common.sh
source "$root/scripts/lib/common.sh"
load_versions

ok() { printf 'ok    %s\n' "$*"; }
skip() { printf 'skip  %s\n' "$*"; }
section() { printf '\n== %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*" >&2; exit 1; }
expect_fail() { if "$@" >/dev/null 2>&1; then return 1; fi; }

# ---------------------------------------------------------------------------
section 'Script syntax'
scripts=("$root/install.sh" "$root/uninstall.sh" "$root/bin/wispr-flow" "$root/bin/wispr-flow-configure"
	"$root/patches/linux-runtime-fixes.sh" "$root/patches/helper-env-fallback.sh" "$root/patches/linux-hub-fixes.sh"
	"$root/patches/linux-notetaker-fixes.sh"
	"$root/scripts/assemble-app.sh" "$root/scripts/build-helper.sh" "$root/scripts/audit-bundle.sh"
	"$root/scripts/pin-latest.sh" "$root/scripts/gen-srcinfo.sh" "$root/scripts/lib/common.sh"
	"$root/tests/fixtures/make-fixtures.sh" "$root/packaging/aur/PKGBUILD" "$root/packaging/aur/wispr-flow-omarchy.install")
for script in "${scripts[@]}"; do
	bash -n "$script" || fail "bash -n $script"
done
ok "bash -n on ${#scripts[@]} scripts"
if have shellcheck; then
	shellcheck -S error -e SC1090,SC1091,SC2016 "$root/install.sh" "$root/uninstall.sh" "$root/bin/wispr-flow" \
		"$root/bin/wispr-flow-configure" "$root/scripts/"*.sh "$root/scripts/lib/common.sh" "$root/patches/"*.sh \
		"$root/tests/smoke.sh" "$root/tests/fixtures/make-fixtures.sh" || fail 'shellcheck reported errors'
	ok 'shellcheck (errors only)'
else
	skip 'shellcheck not installed'
fi
for script in "$root/install.sh" "$root/uninstall.sh" "$root/bin/"* "$root/scripts/"*.sh "$root/patches/"*.sh "$root/tests/fixtures/make-fixtures.sh"; do
	[[ -x $script ]] || fail "$script is not executable"
done
ok 'executable bits'
if grep -R -I -n --exclude-dir=.git --exclude-dir=tests -- 'PLACEHOLDER_' "$root" >/dev/null; then
	fail 'placeholder strings left in the tree'
fi
ok 'no placeholders'

# ---------------------------------------------------------------------------
section 'Pins'
sha_ok "$root/assets/wispr-flow-linux-helper-x86_64" "$HELPER_SHA256" || fail 'helper asset does not match HELPER_SHA256'
grep -q 'ELF 64-bit.*x86-64' <<< "$(file "$root/assets/wispr-flow-linux-helper-x86_64")" || fail 'helper asset is not an x86_64 ELF'
ok 'helper asset matches versions.env'
for pair in \
	"PATCHED_UINPUT_SHA256:$root/patches/helper/uinput.rs" \
	"TERMINAL_PATCH_SHA256:$root/patches/helper/terminal-paste.patch"; do
	const="${pair%%:*}"
	path="${pair#*:}"
	pinned="$(sed -n "s/^readonly $const='\([0-9a-f]*\)'$/\1/p" "$root/scripts/build-helper.sh")"
	[[ -n $pinned ]] || fail "$const not found in build-helper.sh"
	sha_ok "$path" "$pinned" || fail "$path does not match $const"
done
grep -qF 'has_terminal_tag' "$root/patches/helper/terminal-paste.patch" || fail 'terminal-paste patch lacks the Omarchy tag check'
grep -qF -- '--remap-path-prefix' "$root/scripts/build-helper.sh" || fail 'build-helper.sh is not path-independent'
ok 'helper patch files match build-helper.sh'
grep -qF "$HELPER_RUSTC_VERSION" "$root/docs/UPGRADING.md" || fail 'docs/UPGRADING.md names a different Rust toolchain'

pkgbuild="$root/packaging/aur/PKGBUILD"
bash -c '
	set -Eeuo pipefail
	CARCH=x86_64
	source "$1"
	[[ $pkgname == wispr-flow-omarchy ]]
	[[ $pkgver == "$WISPR_FLOW_VERSION" ]]
	[[ $_electron_version == "$ELECTRON_VERSION" ]]
	[[ $_port_commit == "$PORT_COMMIT" ]]
	[[ $_helper_sha256 == "$HELPER_SHA256" ]]
	[[ $_support_commit =~ ^[0-9a-f]{40}$ ]]
	[[ ${arch[*]} == x86_64 ]]
	[[ $url == https://github.com/dheilandiii/wispr-flow-omarchy ]]
	[[ ${provides[*]} == "wispr-flow=$WISPR_FLOW_VERSION" ]]
	[[ ${conflicts[*]} == wispr-flow ]]
	[[ -z ${replaces+x} ]]
	[[ ${options[*]} == "!strip !debug" ]]
	[[ $install == wispr-flow-omarchy.install ]]
	[[ ${#source[@]} -eq ${#sha256sums[@]} && ${#source[@]} -eq 7 ]]
	[[ ${sha256sums[0]} == SKIP ]]
	[[ ${sha256sums[2]} == "$WISPR_FLOW_NUPKG_SHA256" ]]
	[[ ${sha256sums[3]} == "$ELECTRON_LINUX_X64_SHA256" ]]
	[[ ${sha256sums[4]} == "$SQLITE_SHA256" ]]
	[[ ${source[2]} == "WisprFlow-$WISPR_FLOW_VERSION-full.nupkg::$WISPR_FLOW_NUPKG_BASE_URL/WisprFlow-$WISPR_FLOW_VERSION-full.nupkg" ]]
	[[ ${source[3]} == *"electron-v$ELECTRON_VERSION-linux-x64.zip" ]]
	[[ ${source[4]} == "$SQLITE_NAME::$SQLITE_RELEASE_BASE_URL/$SQLITE_NAME" ]]
	[[ ${noextract[*]} == "WisprFlow-$WISPR_FLOW_VERSION-full.nupkg electron-v$ELECTRON_VERSION-linux-x64.zip" ]]
	[[ $(sha256sum "$2/wispr-flow.desktop" | cut -d" " -f1) == "${sha256sums[5]}" ]]
	[[ $(sha256sum "$2/70-wispr-flow-input.rules" | cut -d" " -f1) == "${sha256sums[6]}" ]]
	for dependency in hicolor-icon-theme hyprland libcups libgcc libstdc++ nodejs pango wl-clipboard xdg-utils libpulse; do
		[[ " ${depends[*]} " == *" $dependency "* ]]
	done
	for dependency in asar git python unzip; do
		[[ " ${makedepends[*]} " == *" $dependency "* ]]
	done
	[[ " ${makedepends[*]} " != *" nodejs "* ]]
	[[ ${optdepends[0]} == uwsm:* ]]
' _ "$pkgbuild" "$root/packaging/aur" || fail 'PKGBUILD does not mirror versions.env'
pkg_functions="$(bash -c 'CARCH=x86_64; source "$1"; declare -f build check package' _ "$pkgbuild")"
if grep -Eiq '(^|[^[:alnum:]_])(sudo|pacman|curl|wget)([^[:alnum:]_]|$)|git[[:space:]]+clone|/usr/local|/home/|\$\{?HOME' <<< "$pkg_functions"; then
	fail 'PKGBUILD build/check/package contain a forbidden operation'
fi
grep -qF -- '--patch-policy strict' <<< "$pkg_functions" || fail 'PKGBUILD must build under the strict policy'
grep -qF -- '--asar-bin /usr/bin/asar' <<< "$pkg_functions" || fail 'PKGBUILD must use /usr/bin/asar'
grep -qF '^SKIPPED' <<< "$pkg_functions" || fail 'PKGBUILD check() must refuse skipped patches'
grep -qF '/opt/wispr-flow-omarchy' <<< "$(bash -c 'CARCH=x86_64; source "$1"; declare -f package' _ "$pkgbuild")" || fail 'package() must install under /opt/wispr-flow-omarchy'
ok 'PKGBUILD mirrors versions.env'
cmp -s <("$root/scripts/gen-srcinfo.sh") "$root/packaging/aur/.SRCINFO" || fail '.SRCINFO is stale; run scripts/gen-srcinfo.sh > packaging/aur/.SRCINFO'
ok '.SRCINFO matches PKGBUILD'
if have makepkg && ((EUID != 0)); then
	cmp -s <(cd "$root/packaging/aur" && makepkg --printsrcinfo) "$root/packaging/aur/.SRCINFO" || fail 'makepkg --printsrcinfo disagrees with .SRCINFO'
	ok 'makepkg --printsrcinfo matches'
else
	skip 'makepkg not available (or running as root)'
fi
if have desktop-file-validate; then
	desktop-file-validate "$root/packaging/aur/wispr-flow.desktop" || fail 'desktop file invalid'
	ok 'desktop-file-validate'
else
	skip 'desktop-file-validate not installed'
fi
python3 - "$root/REUSE.toml" "$root/packaging/aur/REUSE.toml" <<'PY' || fail 'REUSE.toml invalid'
import pathlib, sys, tomllib
for value in sys.argv[1:]:
    data = tomllib.loads(pathlib.Path(value).read_text())
    assert data["version"] == 1 and data["annotations"]
PY
cmp -s "$root/LICENSE" "$root/LICENSES/MIT.txt" || fail 'LICENSES/MIT.txt differs from LICENSE'
cmp -s "$root/LICENSE" "$root/packaging/aur/LICENSE" || fail 'packaging/aur/LICENSE differs from LICENSE'
cmp -s "$root/LICENSES/MIT.txt" "$root/packaging/aur/LICENSES/MIT.txt" || fail 'packaging MIT license differs'
cmp -s "$root/LICENSES/0BSD.txt" "$root/packaging/aur/LICENSES/0BSD.txt" || fail 'packaging 0BSD license differs'
cmp -s "$root/assets/UNLICENSE" "$root/LICENSES/Unlicense.txt" || fail 'Unlicense copies differ'
ok 'REUSE metadata and license copies'
grep -qF 'wispr-flow-omarchy' "$root/bin/wispr-flow" || fail 'launcher lacks the project tag'
grep -qF '# WISPR_FLOW_OMARCHY_WRAPPER=1' "$root/bin/wispr-flow" || fail 'launcher lacks the ownership tag line'
grep -qF '/opt/wispr-flow-omarchy/usr/lib/wispr-flow/wispr-flow' "$root/bin/wispr-flow" || fail 'launcher does not know the AUR install root'
grep -qF 'scripts/assemble-app.sh' "$root/install.sh" || fail 'install.sh does not call the assembler'
grep -qF -- '--asar-bin /usr/bin/asar' "$root/install.sh" || fail 'install.sh must use /usr/bin/asar'
ok 'launcher and installer wiring'

# ---------------------------------------------------------------------------
section 'Configurer: config.json'
configurer="$root/bin/wispr-flow-configure"
home="$tmp/home"; cfg="$tmp/config"; state="$tmp/state"
mkdir -p "$home" "$cfg" "$state"
run_cfg() { HOME="$home" XDG_CONFIG_HOME="$cfg" XDG_STATE_HOME="$state" "$configurer" "$@"; }
config="$cfg/Wispr Flow/config.json"

run_cfg bootstrap >/dev/null
jq -e '.prefs.user.hideFlowBarPermanently == false and .prefs.user.shortcuts["160+162"] == "ptt" and
	(.prefs.cache.splitKeybinds | any(.value == "ptt" and .shortcut == [160, 162]))' "$config" >/dev/null || fail 'bootstrap config'
[[ $(stat -c '%a' "$config") == 600 ]] || fail 'config.json must be 0600'
jq '.prefs.user.shortcuts = {"162+91": "ptt"} | .prefs.cache.splitKeybinds = [{shortcut: [162, 91], value: "ptt"}]' "$config" > "$tmp/custom.json"
mv "$tmp/custom.json" "$config"
run_cfg bootstrap --hide-flow-bar >/dev/null
jq -e '.prefs.user.shortcuts["162+91"] == "ptt" and .prefs.user.modifierShortcut == "164" and .prefs.user.hideFlowBarPermanently == true and
	(.prefs.cache.splitKeybinds | any(.value == "ptt" and .shortcut == [162, 91]))' "$config" >/dev/null || fail 'bootstrap keeps a valid custom shortcut'
run_cfg fix-shortcut >/dev/null
jq -e '.prefs.user.shortcuts["160+162"] == "ptt"' "$config" >/dev/null || fail 'fix-shortcut'
run_cfg flow-bar on >/dev/null
jq -e '.prefs.user.hideFlowBarPermanently == false' "$config" >/dev/null || fail 'flow-bar on'
grep -q '^\[PASS\]' <<< "$(run_cfg check)" || fail 'check should pass'
ok 'bootstrap, fix-shortcut, flow-bar, check'

# ---------------------------------------------------------------------------
section 'Configurer: Hyprland rules (conf, lua, omarchy)'
hypr="$cfg/hypr"
mkdir -p "$hypr"
export WISPR_FLOW_SKIP_HYPR_RELOAD=1

printf '# test hyprland config\n' > "$hypr/hyprland.conf"
[[ $(run_cfg integration-mode) == conf ]] || fail 'conf mode detection'
run_cfg hyprland-rules on >/dev/null
grep -qxF "# >>> $PROJECT rules >>>" "$hypr/hyprland.conf" || fail 'conf block missing'
grep -qF 'match:class ^(wispr-flow|Wispr Flow)$, match:title ^(Flow )?Hub$' "$hypr/wispr-flow.conf" || fail 'conf rules missing'
run_cfg hyprland-rules check || fail 'conf check'
run_cfg hyprland-rules off >/dev/null
! grep -qF "$PROJECT" "$hypr/hyprland.conf" || fail 'conf block not removed'
[[ ! -e $hypr/wispr-flow.conf ]] || fail 'conf rules file not removed'
ok 'conf mode on/check/off'

printf '# before\n%s\n# user setting\n' "# >>> $PROJECT rules >>>" > "$hypr/hyprland.conf"
cp "$hypr/hyprland.conf" "$tmp/malformed.expected"
expect_fail run_cfg hyprland-rules off || fail 'malformed markers must be rejected'
cmp -s "$tmp/malformed.expected" "$hypr/hyprland.conf" || fail 'malformed file must be untouched'
rm -f "$hypr/hyprland.conf"
printf '# symlinked config\n' > "$hypr/hyprland.real.conf"
ln -s hyprland.real.conf "$hypr/hyprland.conf"
run_cfg hyprland-rules on >/dev/null
[[ -L $hypr/hyprland.conf ]] || fail 'symlink replaced'
run_cfg hyprland-rules off >/dev/null
[[ -L $hypr/hyprland.conf ]] && ! grep -qF "$PROJECT" "$hypr/hyprland.real.conf" || fail 'symlink target not cleaned'
printf '# user-owned rules\n' > "$hypr/wispr-flow.conf"
expect_fail run_cfg hyprland-rules on || fail 'foreign wispr-flow.conf must not be overwritten'
grep -qxF '# user-owned rules' "$hypr/wispr-flow.conf" || fail 'foreign file changed'
rm -f "$hypr/wispr-flow.conf"
ok 'conf mode refuses malformed, symlinked, and foreign files'

# Legacy whsprflow-arch blocks are migrated away.
cat > "$hypr/hyprland.conf" <<'LEGACY'
# user config
# >>> whsprflow-arch rules >>>
source = wispr-flow.conf
# <<< whsprflow-arch rules <<<
LEGACY
printf '%s\n' '# Managed by whsprflow-arch. Only the real Flow Hub is affected.' 'windowrule = float on, match:class ^wispr-flow$' > "$hypr/wispr-flow.conf"
run_cfg hyprland-rules on >/dev/null
! grep -qF 'whsprflow-arch' "$hypr/hyprland.conf" || fail 'legacy block not removed'
grep -qF "Managed by $PROJECT" <<< "$(head -1 "$hypr/wispr-flow.conf")" || fail 'legacy rules file not replaced'
run_cfg hyprland-rules off >/dev/null
rm -f "$hypr/hyprland.conf"
ok 'legacy whsprflow-arch conf blocks migrated'

printf '%s\n' '-- plain lua entry' > "$hypr/hyprland.lua"
[[ $(run_cfg integration-mode) == lua ]] || fail 'lua mode detection'
run_cfg hyprland-rules on >/dev/null
grep -qxF -- "-- >>> $PROJECT rules >>>" "$hypr/hyprland.lua" || fail 'lua block missing'
grep -qF "dofile(\"$hypr/wispr-flow.lua\")" "$hypr/hyprland.lua" || fail 'lua dofile missing'
grep -qF 'title = "^(Flow )?Hub$"' "$hypr/wispr-flow.lua" || fail 'lua Hub rule missing'
grep -qF 'pin = true' "$hypr/wispr-flow.lua" || fail 'lua Notetaker popup rule missing'
run_cfg hyprland-rules check || fail 'lua check'
run_cfg hyprland-rules off >/dev/null
! grep -qF "$PROJECT" "$hypr/hyprland.lua" || fail 'lua block not removed'
[[ ! -e $hypr/wispr-flow.lua ]] || fail 'lua rules file not removed'
printf '%s\n' '-- user rules' > "$hypr/wispr-flow.lua"
expect_fail run_cfg hyprland-rules on || fail 'foreign wispr-flow.lua must not be overwritten'
rm -f "$hypr/wispr-flow.lua"
ok 'lua mode on/check/off and foreign-file refusal'

cat > "$hypr/hyprland.lua" <<'OMARCHY'
-- Omarchy's bootstrap keeps path setup out of this user config.
dofile((os.getenv("OMARCHY_PATH") or "/usr/share/omarchy") .. "/default/hypr/bootstrap.lua")
require("default.hypr.omarchy")
require("hypr.bindings")
-- Toggle config flags dynamically.
require("default.hypr.toggles")
OMARCHY
cp "$hypr/hyprland.lua" "$tmp/omarchy-entry.expected"
[[ $(run_cfg integration-mode) == omarchy ]] || fail 'omarchy mode detection'
grep -q 'Omarchy' <<< "$(run_cfg hyprland-rules on)" || fail 'omarchy mode message'
toggles="$state/omarchy/toggles/hypr"
[[ -f $toggles/wispr-flow.lua ]] || fail 'omarchy rules file missing'
grep -qF "Managed by $PROJECT" <<< "$(head -1 "$toggles/wispr-flow.lua")" || fail 'omarchy rules owner header'
grep -qF 'hl.window_rule({' "$toggles/wispr-flow.lua" || fail 'omarchy rules use hl API'
! grep -qF 'o.window' "$toggles/wispr-flow.lua" || fail 'omarchy rules must not depend on Omarchy helpers'
cmp -s "$hypr/hyprland.lua" "$tmp/omarchy-entry.expected" || fail 'omarchy mode must not edit hyprland.lua'
run_cfg hyprland-rules check || fail 'omarchy check'
WISPR_FLOW_HYPR_MODE=lua run_cfg hyprland-rules check && fail 'mode override should change the check target' || true
run_cfg hyprland-rules off >/dev/null
[[ ! -e $toggles/wispr-flow.lua ]] || fail 'omarchy rules file not removed'
cmp -s "$hypr/hyprland.lua" "$tmp/omarchy-entry.expected" || fail 'omarchy mode off edited hyprland.lua'
printf '%s\n' '-- user toggle' > "$toggles/wispr-flow.lua"
expect_fail run_cfg hyprland-rules on || fail 'foreign toggles file must not be overwritten'
rm -f "$toggles/wispr-flow.lua"
ok 'omarchy mode writes only the toggles dir'

# Rollback when Hyprland rejects the new rules: fake hyprctl reports an error
# only while our rules file exists.
fakebin="$tmp/fake-bin"
mkdir -p "$fakebin"
cat > "$fakebin/hyprctl" <<'FAKE'
#!/usr/bin/env bash
[[ ${WISPR_TEST_HYPR_OFFLINE:-0} == 1 ]] && exit 1
case "$1" in
	clients) printf '[{"class":"wispr-flow","title":"Hub","address":"0x123","workspace":{"id":1,"name":"1"}}]\n' ;;
	activeworkspace) printf '{"id":1}\n' ;;
	dispatch) printf 'dispatch rejected\n' >&2; exit 1 ;;
	version) printf 'Hyprland 0.55.1 built from branch main\nTag: v0.55.1\n' ;;
	reload) exit 0 ;;
	configerrors) [[ -n ${WISPR_TEST_RULES_FILE:-} && -f ${WISPR_TEST_RULES_FILE:-} ]] && printf 'config error: bad rule\n'; exit 0 ;;
	*) printf '{}\n' ;;
esac
FAKE
chmod +x "$fakebin/hyprctl"
unset WISPR_FLOW_SKIP_HYPR_RELOAD
if PATH="$fakebin:$PATH" WISPR_TEST_RULES_FILE="$toggles/wispr-flow.lua" run_cfg hyprland-rules on >/dev/null 2>&1; then
	fail 'rules that produce Hyprland config errors must be rolled back'
fi
[[ ! -e $toggles/wispr-flow.lua ]] || fail 'rollback left the rules file behind'
PATH="$fakebin:$PATH" run_cfg hyprland-rules on >/dev/null || fail 'rules on with a healthy fake hyprctl'
PATH="$fakebin:$PATH" run_cfg hyprland-rules off >/dev/null
PATH="$fakebin:$PATH" WISPR_TEST_HYPR_OFFLINE=1 run_cfg hyprland-rules on >/dev/null || fail 'rules on while Hyprland is unreachable'
PATH="$fakebin:$PATH" WISPR_TEST_HYPR_OFFLINE=1 run_cfg hyprland-rules off >/dev/null
export WISPR_FLOW_SKIP_HYPR_RELOAD=1
ok 'rollback on config errors; offline Hyprland tolerated'

# ---------------------------------------------------------------------------
section 'Configurer: autostart'
cat > "$fakebin/uwsm-app" <<'FAKE'
#!/usr/bin/env bash
exit 0
FAKE
chmod +x "$fakebin/uwsm-app"
run_auto() { PATH="$fakebin:$PATH" run_cfg autostart "$@"; }
grep -q 'toggles/hypr/wispr-flow-autostart.lua' <<< "$(run_auto on)" || fail 'omarchy autostart location'
grep -qF 'hl.exec_cmd("uwsm-app -- wispr-flow --background")' "$toggles/wispr-flow-autostart.lua" || fail 'omarchy autostart content'
cmp -s "$hypr/hyprland.lua" "$tmp/omarchy-entry.expected" || fail 'omarchy autostart edited hyprland.lua'
grep -q enabled <<< "$(run_auto status)" || fail 'omarchy autostart status'
run_auto off >/dev/null
[[ ! -e $toggles/wispr-flow-autostart.lua ]] || fail 'omarchy autostart file not removed'
expect_fail run_auto status || fail 'autostart status must be non-zero when disabled'
printf '%s\n' '-- plain lua entry' > "$hypr/hyprland.lua"
run_auto on >/dev/null
grep -qF 'hl.exec_cmd("uwsm-app -- wispr-flow --background")' "$hypr/hyprland.lua" || fail 'lua autostart block'
run_auto status >/dev/null || fail 'lua autostart status'
run_auto off >/dev/null
! grep -qF "$PROJECT" "$hypr/hyprland.lua" || fail 'lua autostart block not removed'
rm -f "$hypr/hyprland.lua"
printf '# conf\n' > "$hypr/hyprland.conf"
run_auto on >/dev/null
grep -qxF 'exec-once = uwsm-app -- wispr-flow --background' "$hypr/autostart.conf" || fail 'conf autostart'
run_auto off >/dev/null
! grep -qF "$PROJECT" "$hypr/autostart.conf" || fail 'conf autostart not removed'
# Legacy autostart blocks in hyprland.lua are removed too.
rm -f "$hypr/hyprland.conf"
printf '%s\n' '-- entry' '-- >>> whsprflow-arch autostart >>>' 'hl.on("hyprland.start", function() end)' '-- <<< whsprflow-arch autostart <<<' > "$hypr/hyprland.lua"
run_auto off >/dev/null
! grep -qF 'whsprflow-arch' "$hypr/hyprland.lua" || fail 'legacy autostart block not removed'
rm -f "$hypr/hyprland.lua"
ok 'autostart in omarchy, lua and conf modes; legacy cleanup'

# ---------------------------------------------------------------------------
section 'Configurer: Notetaker audio (fake pactl)'
cat > "$fakebin/pactl" <<'FAKE'
#!/usr/bin/env bash
# Minimal PulseAudio stand-in tracking loaded modules in a state file.
state="${WISPR_TEST_PACTL_STATE:?}"
touch "$state"
[[ ${WISPR_TEST_PACTL_DOWN:-0} == 1 ]] && exit 1
case "$1 $2" in
	'info ') exit 0 ;;
	'list short')
		case "$3" in
			modules) cat "$state" ;;
			sinks)
				printf '0\talsa_output.fake\tPipeWire\ts16le 2ch 48000Hz\tRUNNING\n'
				awk -F'\t' '$2 == "module-null-sink" { for (i = 3; i <= NF; i++) if ($i ~ /^sink_name=/) { sub(/^sink_name=/, "", $i); printf "%s\t%s\tPipeWire\ts16le 2ch 48000Hz\tIDLE\n", $1 + 100, $i } }' "$state"
				;;
		esac
		;;
	'get-default-sink '*) printf '%s\n' "${WISPR_TEST_DEFAULT_SINK:-alsa_output.fake}" ;;
	'get-default-source '*) printf 'alsa_input.fake\n' ;;
	'load-module '*)
		shift
		id=$(( $(wc -l < "$state") + 1 ))
		printf '%s\t%s\t%s\n' "$id" "$1" "$(printf '%s\t' "${@:2}")" >> "$state"
		printf '%s\n' "$id"
		;;
	'unload-module '*)
		grep -v "^$2"$'\t' "$state" > "$state.tmp" || true
		mv "$state.tmp" "$state"
		;;
	'update-source-proplist '*) exit 0 ;;
	'get-source-volume '*)
		[[ $2 == *.monitor ]] || { printf 'fake pactl: not a monitor: %s\n' "$2" >&2; exit 1; }
		v="${WISPR_TEST_MONITOR_VOLUME:-100}"
		printf 'Volume: front-left: 65536 / %3s%% / 0.00 dB,   front-right: 65536 / %3s%% / 0.00 dB\n        balance 0.00\n' "$v" "$v"
		;;
	'get-source-mute '*) printf 'Mute: %s\n' "${WISPR_TEST_MONITOR_MUTE:-no}" ;;
	'set-source-volume '*) printf '%s %s\n' "$2" "$3" > "$state.monitor" ;;
	'set-source-mute '*) exit 0 ;;
	*) printf 'fake pactl: unsupported %s\n' "$*" >&2; exit 2 ;;
esac
FAKE
chmod +x "$fakebin/pactl"
export WISPR_TEST_PACTL_STATE="$tmp/pactl-state"
run_nt() { PATH="$fakebin:$PATH" run_cfg notetaker-audio "$@"; }
grep -q 'preference: off' <<< "$(run_nt status)" || fail 'notetaker status default'
grep -q 'Notetaker audio mix created' <<< "$(run_nt on)" || fail 'notetaker on'
[[ $(grep -c 'module-loopback' "$WISPR_TEST_PACTL_STATE") -eq 2 ]] || fail 'two loopbacks expected'
grep -q 'module-null-sink.*sink_name=wispr_notetaker_mix' "$WISPR_TEST_PACTL_STATE" || fail 'null sink expected'
grep -q 'source=@DEFAULT_MONITOR@' "$WISPR_TEST_PACTL_STATE" || fail 'monitor loopback expected'
grep -q 'source=@DEFAULT_SOURCE@' "$WISPR_TEST_PACTL_STATE" || fail 'microphone loopback expected'
[[ -f $state/$PROJECT/notetaker-audio ]] || fail 'notetaker preference flag missing'
grep -q 'already present' <<< "$(run_nt on)" || fail 'notetaker on is idempotent'
[[ $(wc -l < "$WISPR_TEST_PACTL_STATE") -eq 3 ]] || fail 'idempotent on loaded extra modules'
grep -q 'present (3 module(s))' <<< "$(run_nt status)" || fail 'notetaker status present'
: > "$WISPR_TEST_PACTL_STATE"
run_nt ensure >/dev/null || fail 'ensure must recreate the mix'
[[ $(wc -l < "$WISPR_TEST_PACTL_STATE") -eq 3 ]] || fail 'ensure did not recreate the mix'
grep -q '3 module(s) unloaded' <<< "$(run_nt off)" || fail 'notetaker off'
[[ ! -s $WISPR_TEST_PACTL_STATE ]] || fail 'modules left loaded'
[[ ! -e $state/$PROJECT/notetaker-audio ]] || fail 'preference flag not removed'
run_nt ensure >/dev/null && [[ ! -s $WISPR_TEST_PACTL_STATE ]] || fail 'ensure must stay quiet when disabled'
WISPR_TEST_DEFAULT_SINK=wispr_notetaker_mix expect_fail run_nt on || fail 'must refuse when the mix is the default output'
WISPR_TEST_PACTL_DOWN=1 expect_fail run_nt on || fail 'must fail when PipeWire is unreachable'
WISPR_TEST_PACTL_DOWN=1 run_nt ensure >/dev/null || fail 'ensure must not fail when PipeWire is unreachable'
ok 'notetaker-audio on/off/status/ensure'

# Both Notetaker paths read the default output's monitor; its own volume must be 100%.
run_sa() { PATH="$fakebin:$PATH" run_cfg system-audio "$@"; }
grep -qx 'Default output monitor alsa_output.fake.monitor at 100%' <<< "$(run_sa check)" || fail 'system-audio check at 100%'
WISPR_TEST_MONITOR_VOLUME=8 expect_fail run_sa check || fail 'system-audio check must fail below 100%'
grep -q 'alsa_output.fake.monitor at 8%: Notetaker hears system audio attenuated' <<< "$(WISPR_TEST_MONITOR_VOLUME=8 run_sa check || true)" || fail 'system-audio check must print the percentage'
WISPR_TEST_MONITOR_MUTE=yes expect_fail run_sa check || fail 'system-audio check must fail when the monitor is muted'
grep -q 'is muted' <<< "$(WISPR_TEST_MONITOR_MUTE=yes run_sa check || true)" || fail 'system-audio check must report a muted monitor'
WISPR_TEST_PACTL_DOWN=1 expect_fail run_sa check || fail 'system-audio check must fail when PipeWire is unreachable'
expect_fail run_sa bogus || fail 'system-audio must reject unknown subcommands'
rm -f "$WISPR_TEST_PACTL_STATE.monitor"
grep -q 'set to 100%' <<< "$(run_sa fix)" || fail 'system-audio fix'
grep -qx 'alsa_output.fake.monitor 100%' "$WISPR_TEST_PACTL_STATE.monitor" || fail 'system-audio fix must set the default output monitor to 100%'
WISPR_TEST_DEFAULT_SINK=other.sink run_sa fix >/dev/null
grep -qx 'other.sink.monitor 100%' "$WISPR_TEST_PACTL_STATE.monitor" || fail 'system-audio fix must follow the default sink'
grep -q 'Default output monitor alsa_output.fake.monitor at 100%' <<< "$(run_nt status)" || fail 'notetaker status must report the monitor volume'
grep -q 'at 8%.*(run wispr-flow --system-audio fix)' <<< "$(WISPR_TEST_MONITOR_VOLUME=8 run_nt status)" || fail 'notetaker status must flag a quiet monitor'
grep -q 'WARNING: Default output monitor alsa_output.fake.monitor at 8%' <<< "$(WISPR_TEST_MONITOR_VOLUME=8 run_nt on 2>&1)" || fail 'notetaker on must warn about a quiet monitor'
run_nt off >/dev/null
[[ ! -s $WISPR_TEST_PACTL_STATE ]] || fail 'modules left loaded after the monitor tests'
ok 'system-audio check/fix; monitor volume in notetaker-audio status/on'

# ---------------------------------------------------------------------------
section 'Launcher'
app="$tmp/app/usr/lib/wispr-flow"
mkdir -p "$app/resources/Release"
cat > "$app/launcher-common.sh" <<'STUB'
setup_logging() { log_file="${TMPDIR:?}/wispr-flow-test.log"; }
setup_electron_env() { :; }
cleanup_stale_lock() { :; }
detect_display_backend() { :; }
check_display() { return 0; }
log_message() { :; }
log_session_env() { :; }
run_doctor() { printf 'doctor stub\n'; return 0; }
build_electron_args() {
	electron_args=(--class=Wispr)
	[[ ${WISPR_USE_WAYLAND:-0} == 1 ]] && electron_args+=(--enable-features=UseOzonePlatform --ozone-platform=wayland --enable-features=WaylandWindowDecorations)
}
STUB
cat > "$app/wispr-flow" <<'STUB'
#!/usr/bin/env bash
printf 'wayland=%s\nloopback=%s\nargs=%s\n' "${WISPR_USE_WAYLAND-unset}" "${WISPR_FLOW_NOTETAKER_LOOPBACK-unset}" "$*" > "${WISPR_TEST_OUTPUT:?}"
STUB
chmod +x "$app/wispr-flow"
cp /bin/true "$app/resources/Release/wispr-flow-linux-helper"
printf '1.6.774\n' > "$app/app-version"
printf 'wispr-flow=1.6.774\nnotetaker-ui=yes\n' > "$app/features"
printf 'APPLIED port/helper-resolver\nSKIPPED linux-runtime-fixes/tour: test\n' > "$app/patch-report.txt"
cat > "$fakebin/xdg-mime" <<'FAKE'
#!/usr/bin/env bash
set -Eeuo pipefail
case "${1:-}" in
	default) [[ $# -eq 3 && $2 == wispr-flow.desktop && $3 == x-scheme-handler/wispr-flow ]]; printf '%s\n' "$2" > "${WISPR_TEST_XDG_DIR:?}/default" ;;
	query) [[ ${2:-} == default && ${3:-} == x-scheme-handler/wispr-flow ]]; [[ -f ${WISPR_TEST_XDG_DIR:?}/default ]] && cat "$WISPR_TEST_XDG_DIR/default" ;;
	*) exit 2 ;;
esac
FAKE
cat > "$fakebin/sudo" <<'FAKE'
#!/usr/bin/env bash
printf 'sudo called\n' > "${WISPR_TEST_XDG_DIR:?}/sudo-called"
exit 99
FAKE
chmod +x "$fakebin/xdg-mime" "$fakebin/sudo"
launcher="$root/bin/wispr-flow"
run_launcher() { PATH="$fakebin:$PATH" HOME="$home" XDG_CONFIG_HOME="$cfg" XDG_STATE_HOME="$state" WISPR_FLOW_INSTALL_ROOT="$tmp/app" WISPR_FLOW_ALLOW_ROOT=1 "$launcher" "$@"; }

mkdir -p "$tmp/xdg-state"
printf '# setup Hyprland config\n' > "$hypr/hyprland.conf"
XDG_CURRENT_DESKTOP=Hyprland HYPRLAND_INSTANCE_SIGNATURE=test WISPR_TEST_XDG_DIR="$tmp/xdg-state" run_launcher --setup >/dev/null || fail '--setup on Hyprland'
jq -e '.prefs.user.hideFlowBarPermanently == true' "$config" >/dev/null || fail '--setup must hide the Flow Bar on Hyprland'
grep -qxF 'wispr-flow.desktop' "$tmp/xdg-state/default" || fail 'login callback not registered'
grep -qxF "# >>> $PROJECT rules >>>" "$hypr/hyprland.conf" || fail '--setup did not install Hyprland rules'
[[ ! -e $tmp/xdg-state/sudo-called ]] || fail '--setup must never call sudo'
mkdir -p "$tmp/gnome-config" "$tmp/gnome-home" "$tmp/gnome-xdg"
PATH="$fakebin:$PATH" HOME="$tmp/gnome-home" XDG_CONFIG_HOME="$tmp/gnome-config" XDG_STATE_HOME="$tmp/gnome-state" XDG_CURRENT_DESKTOP=GNOME HYPRLAND_INSTANCE_SIGNATURE= \
	WISPR_FLOW_INSTALL_ROOT="$tmp/app" WISPR_TEST_XDG_DIR="$tmp/gnome-xdg" WISPR_FLOW_ALLOW_ROOT=1 "$launcher" --setup >/dev/null || fail '--setup on GNOME'
jq -e '.prefs.user.hideFlowBarPermanently == false' "$tmp/gnome-config/Wispr Flow/config.json" >/dev/null || fail 'GNOME keeps the Flow Bar'
[[ ! -e $tmp/gnome-config/hypr/wispr-flow.conf ]] || fail 'GNOME must not get Hyprland rules'
run_launcher --hyprland-rules off >/dev/null
ok '--setup on Hyprland and GNOME'

expect_fail run_launcher --hide || fail '--hide must propagate a hyprctl dispatch failure'
grep -qF 'Main Electron processes: 0' <<< "$(run_launcher --status)" || fail '--status'
grep -qF 'Wispr Flow 1.6.774' <<< "$(run_launcher --version)" || fail '--version'
grep -qF -- '--notetaker-audio' <<< "$(run_launcher --help)" || fail '--help'
grep -qF -- '--system-audio check|fix' <<< "$(run_launcher --help)" || fail '--help lacks --system-audio'
doctor_out="$(XDG_CURRENT_DESKTOP=Hyprland WISPR_TEST_XDG_DIR="$tmp/xdg-state" run_launcher --doctor 2>&1)" || true
grep -qF 'doctor stub' <<< "$doctor_out" || fail 'doctor must run the port checks'
grep -qF 'Omarchy / Hyprland integration' <<< "$doctor_out" || fail 'doctor lacks the Omarchy section'
grep -qF 'Hyprland 0.55: Lua config and dispatch available' <<< "$doctor_out" || fail 'doctor Hyprland version line'
grep -qF '1 optional Linux patch(es) were skipped' <<< "$doctor_out" || fail 'doctor must report skipped optional patches'
grep -qF 'notetaker-ui=yes' <<< "$doctor_out" || fail 'doctor must print bundle features'
grep -qF 'lacks the display-media patch' <<< "$doctor_out" || fail 'doctor must warn when the display-media patch is missing'
grep -qF '[PASS] Default output monitor alsa_output.fake.monitor at 100%' <<< "$doctor_out" || fail 'doctor must report the default output monitor volume'
doctor_quiet="$(XDG_CURRENT_DESKTOP=Hyprland WISPR_TEST_XDG_DIR="$tmp/xdg-state" WISPR_TEST_MONITOR_VOLUME=8 run_launcher --doctor 2>&1)" || true
grep -qF '[WARN] Default output monitor alsa_output.fake.monitor at 8%' <<< "$doctor_quiet" || fail 'doctor must warn about a quiet monitor'
grep -qF 'wispr-flow --system-audio fix' <<< "$doctor_quiet" || fail 'doctor must name the fix for a quiet monitor'
grep -qF 'Login callback wispr-flow: registered' <<< "$doctor_out" || fail 'doctor callback line'
ok '--status, --version, --help, --doctor'

# The launch cases below describe a non-Hyprland session unless they set one
# themselves; do not inherit the developer's desktop (WAYLAND_DISPLAY alone
# makes the launcher pick native Wayland and the stub emit Wayland features).
unset WAYLAND_DISPLAY HYPRLAND_INSTANCE_SIGNATURE WISPR_USE_WAYLAND
export XDG_CURRENT_DESKTOP=
launch() { WISPR_TEST_OUTPUT="$tmp/electron.out" run_launcher "$@"; }
launch >/dev/null
! grep -qF 'PulseaudioLoopbackForScreenShare' "$tmp/electron.out" || fail 'launcher must not pass the inert PulseaudioLoopbackForScreenShare flag'
! grep -qF 'enable-features' "$tmp/electron.out" || fail 'launcher must not pass Chromium feature flags of its own'
grep -qxF 'loopback=1' "$tmp/electron.out" || fail 'launcher must export WISPR_FLOW_NOTETAKER_LOOPBACK=1 for the patched display-media handler'
WISPR_FLOW_NOTETAKER_LOOPBACK=0 launch
grep -qxF 'loopback=0' "$tmp/electron.out" || fail 'loopback opt-out must reach Electron'
WISPR_TEST_MONITOR_VOLUME=8 launch || fail 'a quiet monitor must not stop the launch'
WISPR_FLOW_BACKEND=auto WISPR_USE_WAYLAND=1 launch
grep -qxF 'wayland=unset' "$tmp/electron.out" || fail 'auto backend must unset WISPR_USE_WAYLAND'
WISPR_FLOW_BACKEND=wayland launch
grep -qxF 'wayland=1' "$tmp/electron.out" || fail 'wayland backend'
[[ $(grep -o -- '--enable-features=' "$tmp/electron.out" | wc -l) -eq 1 ]] || fail 'multiple --enable-features must be merged'
grep -qF -- '--enable-features=UseOzonePlatform,WaylandWindowDecorations' "$tmp/electron.out" || fail 'feature merge order'
! grep -qF -- '--enable-features=UseOzonePlatform --' "$tmp/electron.out" || fail 'merged switch must replace the originals'
jq '.prefs.user.hideFlowBarPermanently = false' "$config" > "$tmp/bar.json" && mv "$tmp/bar.json" "$config"
XDG_CURRENT_DESKTOP=Hyprland WAYLAND_DISPLAY=wayland-test launch
grep -qF -- '--ozone-platform=x11' "$tmp/electron.out" || fail 'persistent Flow Bar must use XWayland'
jq '.prefs.user.hideFlowBarPermanently = true' "$config" > "$tmp/hidden.json" && mv "$tmp/hidden.json" "$config"
XDG_CURRENT_DESKTOP=Hyprland WAYLAND_DISPLAY=wayland-test launch
grep -qxF 'wayland=1' "$tmp/electron.out" || fail 'hidden Flow Bar must use native Wayland'
! grep -qF -- '--ozone-platform=x11' "$tmp/electron.out" || fail 'native Wayland must not force x11'
XDG_CURRENT_DESKTOP=Hyprland WAYLAND_DISPLAY=wayland-test WISPR_FLOW_TRANSIENT_STATUS_WINDOW=0 launch
grep -qxF 'wayland=1' "$tmp/electron.out" || fail 'indicator disabled still native Wayland'
WISPR_FLOW_BACKEND=bogus expect_fail launch || fail 'invalid backend must be rejected'
# The launcher recreates the Notetaker mix when it was enabled.
: > "$WISPR_TEST_PACTL_STATE"
run_nt on >/dev/null
: > "$WISPR_TEST_PACTL_STATE"
launch
[[ $(wc -l < "$WISPR_TEST_PACTL_STATE") -eq 3 ]] || fail 'launcher must recreate the Notetaker mix'
run_nt off >/dev/null
ok 'backend selection, feature merging, Notetaker mix on launch'

# ---------------------------------------------------------------------------
section 'Patch scripts on synthetic bundles'
fixtures="$tmp/fixtures"
have_fixtures=false
if have zip && (have asar || have npx); then
	# Fixtures follow the pinned Electron so the pin-latest checks stay offline.
	mk() { "$root/tests/fixtures/make-fixtures.sh" "$@" --electron "$ELECTRON_VERSION" >/dev/null; }
	for flavour in old new unknown dock; do
		mk "$fixtures/$flavour" --flavour "$flavour"
	done
	mk "$fixtures/skip" --flavour new --skip-optional
	mk "$fixtures/electron43" --flavour new --windows-electron 43.0.0
	mk "$fixtures/v999" --flavour new --version 9.9.9
	mk "$fixtures/v999nover" --flavour dock --version 9.9.9 --no-version-file
	have_fixtures=true
	ok 'fixtures generated'
else
	skip 'fixtures need zip and asar/npx'
fi

if $have_fixtures; then
	runtime_fixes="$root/patches/linux-runtime-fixes.sh"
	for flavour in old new unknown dock; do
		cp "$fixtures/$flavour/app/.webpack/main/index.js" "$tmp/main-$flavour.js"
		report="$tmp/report-$flavour.txt"
		"$runtime_fixes" "$tmp/main-$flavour.js" --policy strict --report "$report" >/dev/null || fail "runtime fixes ($flavour) strict"
		[[ $(grep -c '^APPLIED' "$report") -eq 13 ]] || fail "runtime fixes ($flavour) must apply 13 sub-patches"
		[[ $(grep -o 'WISPR_LINUX_[A-Z_]*' "$tmp/main-$flavour.js" | sort -u | wc -l) -eq 14 ]] || fail "runtime fixes ($flavour) markers"
		node --check "$tmp/main-$flavour.js" || fail "runtime fixes ($flavour) broke the JS"
		cp "$tmp/main-$flavour.js" "$tmp/main-$flavour.once.js"
		"$runtime_fixes" "$tmp/main-$flavour.js" --policy strict >/dev/null || fail "runtime fixes ($flavour) re-run"
		cmp -s "$tmp/main-$flavour.js" "$tmp/main-$flavour.once.js" || fail "runtime fixes ($flavour) not idempotent"
	done
	grep -qF '"1"===process.env.WISPR_FLOW_TRANSIENT_STATUS_WINDOW&&ne.RA.statusWindow?.showInactive()' "$tmp/main-old.js" || fail 'old flavour transient show'
	grep -qF '(0,V.Bn)(ne.RA.hubWindow,E.Y6.PlayDictationStartSound)' "$tmp/main-old.js" || fail 'old flavour start sound channel'
	grep -qF '(0,K.Bn)(ie.RA.hubWindow,_.Y6.PlayDictationStopSound)' "$tmp/main-new.js" || fail 'new flavour stop sound channel'
	grep -qF '(0,Q.Bn)(zz.RA.hubWindow,T.Y6.PlayDictationStartSound)' "$tmp/main-unknown.js" || fail 'unknown flavour must derive the sound channel'
	grep -qF 'Math.round(600*(' "$tmp/main-unknown.js" || fail 'unknown flavour must derive the status height'
	grep -qF 'zoomFactor:process.env.WISPR_FLOW_STATUS_ZOOM' "$tmp/main-new.js" || fail 'zoom prefs'
	grep -qF 'WISPR_FLOW_STATUS_Y||"0.83"' "$tmp/main-new.js" || fail 'geometry'
	grep -qF 'y:Math.round(l+m*parseFloat(process.env.WISPR_FLOW_STATUS_Y||"0.83")-s/2)' "$tmp/main-dock.js" || fail 'dock flavour must derive the geometry identifiers'
	grep -qF ',d,/*WISPR_LINUX_COMPACT_STATUS_WINDOW*/' "$tmp/main-dock.js" || fail 'dock flavour must keep the side-dock size argument'
	grep -qF 'Math.round(586*(' "$tmp/main-dock.js" || fail 'dock flavour status height'
	cp "$fixtures/new/app/.webpack/renderer/hub/index.js" "$tmp/none.js"
	expect_fail "$runtime_fixes" "$tmp/none.js" --policy strict || fail 'strict must fail without anchors'
	"$runtime_fixes" "$tmp/none.js" --policy tolerant --report "$tmp/none-report.txt" >/dev/null || fail 'tolerant must succeed without anchors'
	[[ $(grep -c '^SKIPPED' "$tmp/none-report.txt") -eq 13 ]] || fail 'tolerant must report every skip'
	cmp -s "$tmp/none.js" "$fixtures/new/app/.webpack/renderer/hub/index.js" || fail 'tolerant with no anchors must leave the file untouched'
	ok 'linux-runtime-fixes: strict on four flavours, idempotent, tolerant fallback'

	hub_fixes="$root/patches/linux-hub-fixes.sh"
	cp "$fixtures/new/app/.webpack/main/index.js" "$tmp/hub.js"
	"$hub_fixes" "$tmp/hub.js" --policy strict >/dev/null || fail 'hub fixes strict'
	for marker in WISPR_LINUX_WARM_DEEPLINK WISPR_LINUX_HUB_FOCUSABLE WISPR_LINUX_SINGLETON_EXIT; do
		grep -qF "$marker" "$tmp/hub.js" || fail "hub fixes marker $marker"
	done
	grep -qF 'focusable:!0/*WISPR_LINUX_HUB_FOCUSABLE*/' "$tmp/hub.js" || fail 'hub focusable rewrite'
	grep -qF 'void e.app.exit(/*WISPR_LINUX_SINGLETON_EXIT*/)' "$tmp/hub.js" || fail 'singleton exit rewrite'
	cp "$fixtures/skip/app/.webpack/main/index.js" "$tmp/hub-skip.js"
	expect_fail "$hub_fixes" "$tmp/hub-skip.js" --policy strict || fail 'hub fixes strict must fail on the skip fixture'
	"$hub_fixes" "$tmp/hub-skip.js" --policy tolerant --report "$tmp/hub-skip-report.txt" >/dev/null || fail 'hub fixes tolerant'
	grep -q '^SKIPPED linux-hub-fixes/warm-deeplink' "$tmp/hub-skip-report.txt" || fail 'hub fixes report'
	ok 'linux-hub-fixes'

	cp "$fixtures/new/app/.webpack/main/index.js" "$tmp/env.js"
	"$root/patches/helper-env-fallback.sh" "$tmp/env.js" >/dev/null || fail 'helper-env-fallback'
	grep -qF '/*WISPR_LINUX_HELPER_ENV*/...process.env,sentryDSN:f.kL' "$tmp/env.js" || fail 'helper-env-fallback insertion'
	grep -q 'Already patched' <<< "$("$root/patches/helper-env-fallback.sh" "$tmp/env.js")" || fail 'helper-env-fallback idempotency'
	cp "$fixtures/old/app/.webpack/main/index.js" "$tmp/env-old.js"
	"$root/patches/helper-env-fallback.sh" "$tmp/env-old.js" >/dev/null || fail 'helper-env-fallback on the inline env shape'
	ok 'helper-env-fallback'

	notetaker_fixes="$root/patches/linux-notetaker-fixes.sh"
	for flavour in new unknown dock; do
		cp "$fixtures/$flavour/app/.webpack/main/index.js" "$tmp/nt-$flavour.js"
		"$notetaker_fixes" "$tmp/nt-$flavour.js" --policy strict --report "$tmp/nt-$flavour.txt" >/dev/null || fail "notetaker fixes ($flavour) strict"
		grep -qx 'APPLIED linux-notetaker-fixes/display-media' "$tmp/nt-$flavour.txt" || fail "notetaker fixes ($flavour) report"
		grep -qF 'if("linux"===process.platform&&"1"!==process.env.WISPR_FLOW_NOTETAKER_LOOPBACK/*WISPR_LINUX_NOTETAKER_LOOPBACK_GATE*/)return s().info(' "$tmp/nt-$flavour.js" || fail "notetaker gate ($flavour)"
		grep -qF 'setDisplayMediaRequestHandler((e,t)=>{if("linux"===process.platform/*WISPR_LINUX_NOTETAKER_LOOPBACK_BRANCH*/)return void t({audio:"loopback"});if("win32"===process.platform)' "$tmp/nt-$flavour.js" || fail "notetaker branch ($flavour)"
		node --check "$tmp/nt-$flavour.js" || fail "notetaker fixes ($flavour) broke the JS"
		cp "$tmp/nt-$flavour.js" "$tmp/nt-$flavour.once.js"
		"$notetaker_fixes" "$tmp/nt-$flavour.js" --policy strict >/dev/null || fail "notetaker fixes ($flavour) re-run"
		cmp -s "$tmp/nt-$flavour.js" "$tmp/nt-$flavour.once.js" || fail "notetaker fixes ($flavour) not idempotent"
	done
	cp "$fixtures/old/app/.webpack/main/index.js" "$tmp/nt-old.js"
	"$notetaker_fixes" "$tmp/nt-old.js" --policy strict --report "$tmp/nt-old.txt" >/dev/null || fail 'notetaker fixes must accept a bundle without Notetaker'
	grep -q '^ABSENT linux-notetaker-fixes/display-media' "$tmp/nt-old.txt" || fail 'notetaker fixes must report ABSENT without a handler'
	cmp -s "$tmp/nt-old.js" "$fixtures/old/app/.webpack/main/index.js" || fail 'ABSENT must leave the bundle untouched'
	cp "$fixtures/skip/app/.webpack/main/index.js" "$tmp/nt-skip.js"
	expect_fail "$notetaker_fixes" "$tmp/nt-skip.js" --policy strict || fail 'notetaker fixes strict must fail on the skip fixture'
	"$notetaker_fixes" "$tmp/nt-skip.js" --policy tolerant --report "$tmp/nt-skip.txt" >/dev/null || fail 'notetaker fixes tolerant'
	grep -q '^SKIPPED linux-notetaker-fixes/display-media' "$tmp/nt-skip.txt" || fail 'notetaker fixes tolerant report'
	cmp -s "$tmp/nt-skip.js" "$fixtures/skip/app/.webpack/main/index.js" || fail 'tolerant skip must leave the bundle untouched'
	ok 'linux-notetaker-fixes: applied, absent, skipped, idempotent'
fi

# ---------------------------------------------------------------------------
section 'Assembler end to end'
port_dir="${WISPR_FLOW_PORT_DIR:-}"
if [[ -z $port_dir ]]; then
	candidate="${XDG_CACHE_HOME:-$HOME/.cache}/$PROJECT/port-$PORT_COMMIT"
	[[ -d $candidate/.git ]] && port_dir="$candidate"
fi
if [[ -z $port_dir && ${WISPR_FLOW_SMOKE_CLONE_PORT:-1} == 1 ]] && have git; then
	if git clone --quiet --no-checkout "$PORT_REPO" "$tmp/port" 2>/dev/null && git -C "$tmp/port" checkout --quiet "$PORT_COMMIT" 2>/dev/null; then
		port_dir="$tmp/port"
	fi
fi
if $have_fixtures && [[ -n $port_dir && -f $port_dir/scripts/patches/helper-resolver.sh ]]; then
	asar_cmd="$(cat "$fixtures/new/asar-path")"
	assemble() {
		local flavour="$1" policy="$2" out="$3" version="${4:-1.6.774}" electron="${5:-$ELECTRON_VERSION}"
		"$root/scripts/assemble-app.sh" --version "$version" \
			--nupkg "$fixtures/$flavour/WisprFlow-$version-full.nupkg" \
			--electron-zip "$fixtures/$flavour/electron-v$electron-linux-x64.zip" \
			--electron-version "$electron" \
			--sqlite "$fixtures/$flavour/node_sqlite3-x86_64.node" \
			--helper "$fixtures/$flavour/wispr-flow-linux-helper-x86_64" \
			--port-dir "$port_dir" --output-dir "$out" --patch-policy "$policy" --asar-bin "$asar_cmd"
	}
	assemble old strict "$tmp/rt-old" >"$tmp/asm-old.log" 2>&1 || { cat "$tmp/asm-old.log"; fail 'assemble old/strict'; }
	for f in wispr-flow chrome-sandbox resources/app.asar resources/Release/wispr-flow-linux-helper resources/Release/helper.UNLICENSE \
		launcher-common.sh doctor.sh app-version features patch-report.txt \
		resources/app.asar.unpacked/.webpack/main/native_modules/build/Release/node_sqlite3.node; do
		[[ -f $tmp/rt-old/$f ]] || fail "runtime is missing $f"
	done
	[[ ! -e $tmp/rt-old/electron ]] || fail 'electron binary must be renamed'
	[[ $(< "$tmp/rt-old/app-version") == 1.6.774 ]] || fail 'app-version'
	grep -qxF 'notetaker-ui=no' "$tmp/rt-old/features" || fail 'old fixture must report no Notetaker UI'
	grep -qxF "client-electron=$ELECTRON_VERSION" "$tmp/rt-old/features" || fail 'features must record the client Electron'
	! grep -q '^SKIPPED' "$tmp/rt-old/patch-report.txt" || fail 'strict build must not skip'
	grep -q '^ABSENT linux-notetaker-fixes/display-media' "$tmp/rt-old/patch-report.txt" || fail 'old fixture must report the Notetaker fix as absent'
	! grep -aqF 'WISPR_LINUX_NOTETAKER_LOOPBACK' "$tmp/rt-old/resources/app.asar" || fail 'old fixture must not carry Notetaker markers'
	! grep -qE 'crypt32-|[.]orig$' <<< "$($asar_cmd list "$tmp/rt-old/resources/app.asar")" || fail 'asar carries crypt32 or backups'
	for marker in WISPR_LINUX_HELPER_BRANCH WISPR_LINUX_HELPER_ENV WISPR_LINUX_DEEPLINK WISPR_LINUX_WIN32_CHROME WISPR_LINUX_RENDERER_ISWIN \
		WISPR_LINUX_FRAMELESS WISPR_LINUX_WARM_DEEPLINK WISPR_LINUX_HUB_FOCUSABLE WISPR_LINUX_SINGLETON_EXIT WISPR_LINUX_HIDE_STATUS_WINDOW_SHOW WISPR_LINUX_STATUS_TOUR WISPR_LINUX_STATUS_POSITION; do
		grep -aqF "$marker" "$tmp/rt-old/resources/app.asar" || fail "asar lacks $marker"
	done
	ok 'assemble old/strict'
	assemble new strict "$tmp/rt-new" >"$tmp/asm-new.log" 2>&1 || { cat "$tmp/asm-new.log"; fail 'assemble new/strict'; }
	grep -qxF 'notetaker-ui=yes' "$tmp/rt-new/features" || fail 'new fixture must report the Notetaker UI'
	grep -qF 'renderers=calendar_reminder,hub,meeting_recorder,status' "$tmp/rt-new/features" || fail 'features renderers'
	grep -qF "Electron $ELECTRON_VERSION matches" "$tmp/asm-new.log" || fail 'electron cross-check message'
	for marker in WISPR_LINUX_NOTETAKER_LOOPBACK_GATE WISPR_LINUX_NOTETAKER_LOOPBACK_BRANCH; do
		grep -aqF "$marker" "$tmp/rt-new/resources/app.asar" || fail "asar lacks $marker"
	done
	grep -q '^APPLIED linux-notetaker-fixes/display-media' "$tmp/rt-new/patch-report.txt" || fail 'new fixture must apply the Notetaker fix'
	ok 'assemble new/strict (helper-env fallback path, Notetaker fix)'
	assemble dock strict "$tmp/rt-dock" >"$tmp/asm-dock.log" 2>&1 || { cat "$tmp/asm-dock.log"; fail 'assemble dock/strict'; }
	grep -aqF 'WISPR_LINUX_STATUS_POSITION' "$tmp/rt-dock/resources/app.asar" || fail 'dock asar lacks the geometry marker'
	ok 'assemble dock/strict (1.6.872 layout)'
	# Without a Squirrel version file the client Electron comes from package.json.
	assemble v999nover strict "$tmp/rt-nover" 9.9.9 >"$tmp/asm-nover.log" 2>&1 || { cat "$tmp/asm-nover.log"; fail 'assemble without version file'; }
	grep -qF "Electron $ELECTRON_VERSION matches" "$tmp/asm-nover.log" || fail 'electron cross-check must read package.json'
	ok 'assemble without a Squirrel version file'
	assemble unknown strict "$tmp/rt-unknown" >"$tmp/asm-unknown.log" 2>&1 || { cat "$tmp/asm-unknown.log"; fail 'assemble unknown/strict'; }
	ok 'assemble unknown/strict (derived identifiers)'
	expect_fail assemble skip strict "$tmp/rt-skip-strict" || fail 'skip fixture must fail under strict'
	[[ ! -e $tmp/rt-skip-strict ]] || fail 'failed assembly must leave no output'
	assemble skip tolerant "$tmp/rt-skip" >"$tmp/asm-skip.log" 2>&1 || { cat "$tmp/asm-skip.log"; fail 'assemble skip/tolerant'; }
	grep -q '^SKIPPED port/linux-window-frame' "$tmp/rt-skip/patch-report.txt" || fail 'tolerant report must list window-frame'
	grep -q '^SKIPPED linux-hub-fixes/warm-deeplink' "$tmp/rt-skip/patch-report.txt" || fail 'tolerant report must list warm-deeplink'
	grep -q '^SKIPPED linux-notetaker-fixes/display-media' "$tmp/rt-skip/patch-report.txt" || fail 'tolerant report must list display-media'
	! grep -aqF 'WISPR_LINUX_NOTETAKER_LOOPBACK' "$tmp/rt-skip/resources/app.asar" || fail 'skipped Notetaker fix must leave no marker'
	grep -qxF 'patch-policy=tolerant' "$tmp/rt-skip/features" || fail 'features must record the policy'
	ok 'assemble skip: strict fails, tolerant records skips'
	expect_fail assemble electron43 strict "$tmp/rt-e43" || fail 'Electron major mismatch must fail'
	assemble electron43 strict "$tmp/rt-e43" >"$tmp/asm-e43.log" 2>&1 || true
	grep -q 'Electron major mismatch' "$tmp/asm-e43.log" || fail 'Electron mismatch message'
	mkdir -p "$tmp/rt-exists"
	expect_fail assemble new strict "$tmp/rt-exists" || fail 'existing output dir must be refused'
	expect_fail "$root/scripts/assemble-app.sh" --version || fail 'flag without value must fail'
	assembler_home="$tmp/assembler-home"
	if HOME="$assembler_home" "$root/scripts/assemble-app.sh" >/dev/null 2>&1; then fail 'assembler must reject missing flags'; fi
	[[ ! -e $assembler_home ]] || fail 'assembler must not create HOME'
	ok 'assembler argument validation'

	audit_out="$("$root/scripts/audit-bundle.sh" --nupkg "$fixtures/new/WisprFlow-1.6.774-full.nupkg" --port-dir "$port_dir" 2>&1)" || fail 'audit new fixture'
	grep -qF 'Notetaker UI:       present in this bundle' <<< "$audit_out" || fail 'audit Notetaker detection'
	grep -qF '0 essential failure(s), 0 optional failure(s)' <<< "$audit_out" || fail 'audit summary'
	audit_skip="$("$root/scripts/audit-bundle.sh" --nupkg "$fixtures/skip/WisprFlow-1.6.774-full.nupkg" --port-dir "$port_dir" 2>&1)" || fail 'audit skip fixture must pass without --strict'
	grep -qF '3 optional failure(s)' <<< "$audit_skip" || fail 'audit must count optional failures'
	audit_old="$("$root/scripts/audit-bundle.sh" --nupkg "$fixtures/old/WisprFlow-1.6.774-full.nupkg" --port-dir "$port_dir" 2>&1)" || fail 'audit old fixture'
	grep -qF '0 essential failure(s), 0 optional failure(s)' <<< "$audit_old" || fail 'audit must not count an absent Notetaker handler as a failure'
	grep -qF 'n/a (bundle has no display-media handler' <<< "$audit_old" || fail 'audit must show the absent Notetaker fix'
	audit_nover="$("$root/scripts/audit-bundle.sh" --nupkg "$fixtures/v999nover/WisprFlow-9.9.9-full.nupkg" --port-dir "$port_dir" 2>&1)" || fail 'audit fixture without version file'
	grep -qF "Electron (Windows): $ELECTRON_VERSION" <<< "$audit_nover" || fail 'audit must read the client Electron from package.json'
	expect_fail "$root/scripts/audit-bundle.sh" --nupkg "$fixtures/skip/WisprFlow-1.6.774-full.nupkg" --port-dir "$port_dir" --strict || fail 'audit --strict must fail'
	ok 'audit-bundle'

	# pin-latest on a scratch copy of the repo with a local nupkg.
	scratch="$tmp/repo-copy"
	mkdir -p "$scratch"
	cp -a "$root/versions.env" "$root/scripts" "$root/patches" "$scratch/"
	XDG_CACHE_HOME="$tmp/cache" WISPR_FLOW_PORT_DIR="$port_dir" "$scratch/scripts/pin-latest.sh" --nupkg "$fixtures/v999/WisprFlow-9.9.9-full.nupkg" >"$tmp/pin-dry.log" 2>&1 || { cat "$tmp/pin-dry.log"; fail 'pin-latest dry run'; }
	cmp -s "$root/versions.env" "$scratch/versions.env" || fail 'dry run must not write'
	grep -qF 'Dry run' "$tmp/pin-dry.log" || fail 'dry run message'
	XDG_CACHE_HOME="$tmp/cache" WISPR_FLOW_PORT_DIR="$port_dir" "$scratch/scripts/pin-latest.sh" --nupkg "$fixtures/v999/WisprFlow-9.9.9-full.nupkg" --write >"$tmp/pin-write.log" 2>&1 || { cat "$tmp/pin-write.log"; fail 'pin-latest --write'; }
	grep -qF "WISPR_FLOW_VERSION='9.9.9'" "$scratch/versions.env" || fail 'pin-latest did not update the version'
	grep -qF "WISPR_FLOW_NUPKG_SHA256='$(sha256sum "$fixtures/v999/WisprFlow-9.9.9-full.nupkg" | cut -d' ' -f1)'" "$scratch/versions.env" || fail 'pin-latest sha'
	grep -qF "ELECTRON_VERSION='$ELECTRON_VERSION'" "$scratch/versions.env" || fail 'pin-latest must keep Electron when unchanged'
	XDG_CACHE_HOME="$tmp/cache" WISPR_FLOW_PORT_DIR="$port_dir" "$scratch/scripts/pin-latest.sh" --nupkg "$fixtures/v999nover/WisprFlow-9.9.9-full.nupkg" --force >"$tmp/pin-nover.log" 2>&1 || { cat "$tmp/pin-nover.log"; fail 'pin-latest without version file'; }
	grep -qF "Electron in the Windows client: $ELECTRON_VERSION" "$tmp/pin-nover.log" || fail 'pin-latest must read Electron from the client executable'
	bash -c 'source "$1/scripts/lib/common.sh"; load_versions "$1/versions.env"' _ "$scratch" || fail 'rewritten versions.env must still load'
	expect_fail env XDG_CACHE_HOME="$tmp/cache" WISPR_FLOW_PORT_DIR="$port_dir" "$scratch/scripts/pin-latest.sh" --nupkg "$fixtures/electron43/WisprFlow-1.6.774-full.nupkg" --force || fail 'Electron major bump must block pin-latest'
	ok 'pin-latest dry run, --write, Electron blocker'
else
	skip 'assembler end-to-end (needs fixtures and a wispr-flow-linux checkout: set WISPR_FLOW_PORT_DIR)'
fi

printf '\nSmoke tests OK\n'
