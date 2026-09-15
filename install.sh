#!/usr/bin/env bash
# install.sh: build and install Wispr Flow for Omarchy (Arch Linux + Hyprland).
#
# Downloads the official Windows client, Electron for Linux and the SQLite
# module, verifies every SHA-256 against versions.env, assembles the patched
# runtime with scripts/assemble-app.sh and installs it under /opt (or, with
# --user, under ~/.local/share). Then it registers the desktop entry and the
# wispr-flow: login callback, writes a Linux-safe config, installs the Hyprland
# rules and sets up input-device access for the helper.
#
# Run as your desktop user from inside a Hyprland session. The script asks for
# sudo only for the steps that need it.

set -Eeuo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$script_dir/scripts/lib/common.sh"
load_versions

cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/$PROJECT"
legacy_cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/$LEGACY_PROJECT"
system_install=true
system_setup=true
patch_policy="${WISPR_FLOW_PATCH_POLICY:-strict}"
local_nupkg=''
custom_install_root=false
[[ -n ${WISPR_FLOW_INSTALL_ROOT:-} ]] && custom_install_root=true
install_user="$(id -un)"

usage() {
	cat <<'USAGE'
Usage: ./install.sh [--user] [--no-system-setup] [--patch-policy strict|tolerant] [--nupkg FILE]

  --user                 Install under ~/.local/share (no setuid sandbox).
  --no-system-setup      Skip package installation, udev rules and input permissions.
  --patch-policy POLICY  strict (default): every Linux patch must apply.
                         tolerant: optional Hyprland fixes may be skipped when a
                         new Wispr Flow release moved their anchors.
  --nupkg FILE           Use a local copy of the official nupkg (still SHA-256 verified).
  -h, --help             Show this help.

Pins come from versions.env. To move to a newer Wispr Flow release run
scripts/pin-latest.sh first.
USAGE
}

while (($#)); do
	case "$1" in
		--user) system_install=false ;;
		--no-system-setup) system_setup=false ;;
		--patch-policy)
			[[ -n ${2:-} ]] || die '--patch-policy needs a value.'
			patch_policy="$2"
			shift
			;;
		--nupkg)
			[[ -n ${2:-} ]] || die '--nupkg needs a value.'
			local_nupkg="$2"
			shift
			;;
		-h|--help) usage; exit 0 ;;
		*) printf 'Unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
	esac
	shift
done
[[ $patch_policy == strict || $patch_policy == tolerant ]] || die '--patch-policy must be strict or tolerant.'

validate_install_root() {
	local root="$1" wrapper="$2" allow_legacy="$3"
	[[ $root == /* && $root != / && $root != "$HOME" && ! -L $root ]] \
		|| die "Unsafe install path: $root"
	[[ -e $root ]] || return 0
	root_marked "$root" && return 0
	$allow_legacy && wrapper_owned "$wrapper" && return 0
	die "$root already exists and does not carry the $PROJECT ownership marker; refusing to replace it."
}

stop_existing_install() {
	local root="$1"
	[[ -x $root/usr/lib/wispr-flow/wispr-flow ]] || return 0
	info "Stopping the existing installation at $root"
	WISPR_FLOW_INSTALL_ROOT="$root" "$script_dir/bin/wispr-flow" --stop \
		|| die "Could not safely stop the installation at $root."
}

((EUID != 0)) || die 'Run install.sh as your desktop user, not as root; sudo is requested where needed.'
[[ $(uname -s) == Linux ]] || die 'This installer only runs on Linux.'
[[ $(uname -m) == x86_64 ]] || die 'This build is validated for x86_64 only.'

if $system_install; then
	install_root='/opt/wispr-flow'
	bin_target='/usr/local/bin/wispr-flow'
	package_type='system'
	validate_install_root "$install_root" "$bin_target" true
else
	install_root="${WISPR_FLOW_INSTALL_ROOT:-${XDG_DATA_HOME:-$HOME/.local/share}/$PROJECT/app}"
	install_root="$(realpath -m -- "$install_root")"
	bin_target="$HOME/.local/bin/wispr-flow"
	package_type='user'
	allow_legacy=true
	$custom_install_root && allow_legacy=false
	validate_install_root "$install_root" "$bin_target" "$allow_legacy"
fi

if [[ ! -r /etc/arch-release ]]; then
	warn 'Arch Linux not detected; skipping automatic package installation.'
	system_setup=false
fi

if is_omarchy; then
	info "Omarchy $(omarchy_version || echo '(version unknown)') detected"
else
	warn 'Omarchy not detected. The build works on other Hyprland setups, but only Omarchy is the tested target.'
fi

if $system_setup; then
	info 'Installing Arch dependencies'
	deps=(acl alsa-lib asar at-spi2-core curl desktop-file-utils git gtk3 jq libpulse
		libsecret nodejs nss python unzip wl-clipboard xdg-utils xorg-xwayland)
	if have omarchy-pkg-add; then
		omarchy-pkg-add "${deps[@]}"
	else
		sudo pacman -S --needed "${deps[@]}"
	fi
fi

for cmd in asar curl file git jq node python3 sha256sum unzip xdg-mime; do
	have "$cmd" || die "Missing '$cmd'. Install the dependencies or do not use --no-system-setup."
done
[[ -x /usr/bin/asar ]] || die "Missing /usr/bin/asar. Install the Arch package 'asar'."

mkdir -p "$cache_dir"
work_dir="$(mktemp -d "$cache_dir/build.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT

nupkg="$cache_dir/$NUPKG_NAME"
electron_zip="$cache_dir/$ELECTRON_NAME"
helper_bin="$script_dir/assets/wispr-flow-linux-helper-x86_64"
sqlite_bin="$cache_dir/$SQLITE_NAME"

info "Fetching and verifying inputs for Wispr Flow $WISPR_FLOW_VERSION"
if [[ -n $local_nupkg ]]; then
	[[ -f $local_nupkg ]] || die "Local nupkg not found: $local_nupkg"
	sha_ok "$local_nupkg" "$WISPR_FLOW_NUPKG_SHA256" \
		|| die "The local nupkg does not match the pinned SHA-256 for $WISPR_FLOW_VERSION."
	cp -p "$local_nupkg" "$nupkg"
	printf 'Using local nupkg %s (SHA-256 verified)\n' "$local_nupkg"
else
	download "$NUPKG_URL" "$nupkg" "$WISPR_FLOW_NUPKG_SHA256" "$legacy_cache_dir"
fi
download "$ELECTRON_URL" "$electron_zip" "$ELECTRON_LINUX_X64_SHA256" "$legacy_cache_dir"
download "$SQLITE_URL" "$sqlite_bin" "$SQLITE_SHA256" "$legacy_cache_dir"

sha_ok "$helper_bin" "$HELPER_SHA256" \
	|| die 'The bundled Linux helper does not match its pinned SHA-256.'
file "$helper_bin" | grep -q 'ELF 64-bit.*x86-64' \
	|| die 'The bundled helper is not a Linux x86_64 ELF binary.'
printf 'Verified helper (commit %s, SHA-256 OK)\n' "${HELPER_COMMIT:0:12}"

info 'Fetching the pinned Linux port'
port_cache="$cache_dir/port-$PORT_COMMIT"
if [[ ! -d $port_cache/.git ]]; then
	rm -rf "$port_cache"
	git clone --quiet --no-checkout "$PORT_REPO" "$port_cache"
	git -C "$port_cache" checkout --quiet "$PORT_COMMIT"
fi
[[ $(git -C "$port_cache" rev-parse HEAD) == "$PORT_COMMIT" ]] \
	|| die 'The port checkout does not match the pinned commit.'
git -C "$port_cache" status --porcelain | grep -q . && die "The port checkout at $port_cache has local changes; remove it and retry."

info "Assembling the Linux runtime (patch policy: $patch_policy)"
"$script_dir/scripts/assemble-app.sh" \
	--version "$WISPR_FLOW_VERSION" \
	--nupkg "$nupkg" \
	--electron-zip "$electron_zip" \
	--electron-version "$ELECTRON_VERSION" \
	--sqlite "$sqlite_bin" \
	--helper "$helper_bin" \
	--port-dir "$port_cache" \
	--output-dir "$work_dir/runtime" \
	--patch-policy "$patch_policy" \
	--asar-bin /usr/bin/asar

mkdir -p "$work_dir/stage/usr/lib"
mv "$work_dir/runtime" "$work_dir/stage/usr/lib/wispr-flow"
printf '%s\n' "$INSTALL_MARKER_VALUE" > "$work_dir/stage/$INSTALL_MARKER"

if $system_install; then
	stop_existing_install "$install_root"
	info "Installing to $install_root"
	sudo rm -rf "${install_root}.new"
	sudo cp -a "$work_dir/stage" "${install_root}.new"
	sudo chown -R root:root "${install_root}.new"
	sudo chmod 4755 "${install_root}.new/usr/lib/wispr-flow/chrome-sandbox"
	if [[ -d $install_root ]]; then
		sudo rm -rf "${install_root}.old"
		sudo mv "$install_root" "${install_root}.old"
	fi
	sudo mv "${install_root}.new" "$install_root"
	sudo rm -rf "${install_root}.old"
	sudo install -m 0755 "$script_dir/bin/wispr-flow" "$bin_target"
	sudo install -m 0755 "$script_dir/bin/wispr-flow-configure" "$(dirname "$bin_target")/wispr-flow-configure"
else
	stop_existing_install "$install_root"
	info "Installing to $install_root"
	mkdir -p "$(dirname "$install_root")" "$(dirname "$bin_target")"
	rm -rf "${install_root}.new"
	cp -a "$work_dir/stage" "${install_root}.new"
	rm -rf "$install_root"
	mv "${install_root}.new" "$install_root"
	install -m 0755 "$script_dir/bin/wispr-flow" "$bin_target"
	install -m 0755 "$script_dir/bin/wispr-flow-configure" "$(dirname "$bin_target")/wispr-flow-configure"
fi
configurer_target="$(dirname "$bin_target")/wispr-flow-configure"

info 'Registering the application and the wispr-flow: login callback'
applications_dir="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
icons_dir="${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor/scalable/apps"
mkdir -p "$applications_dir" "$icons_dir"
install -m 0644 \
	"$install_root/usr/lib/wispr-flow/resources/assets/logos/flow-symbol.svg" \
	"$icons_dir/wispr-flow.svg"

cat > "$applications_dir/wispr-flow.desktop" <<DESKTOP
[Desktop Entry]
Name=Wispr Flow
Comment=Voice dictation and meeting notes that type into the focused application
GenericName=Voice Dictation
Exec=${bin_target} %U
TryExec=${bin_target}
Icon=wispr-flow
Terminal=false
Type=Application
Categories=Utility;AudioVideo;Audio;Office;
StartupWMClass=wispr-flow
MimeType=x-scheme-handler/wispr-flow;
Keywords=voice;dictation;speech;transcription;notetaker;meeting;
DESKTOP

have update-desktop-database && update-desktop-database "$applications_dir"
xdg-mime default wispr-flow.desktop x-scheme-handler/wispr-flow
[[ $(xdg-mime query default x-scheme-handler/wispr-flow) == wispr-flow.desktop ]] \
	|| die 'Could not register the wispr-flow: login callback.'

hide_bar=false
is_hyprland_session && hide_bar=true
configure_args=(bootstrap)
$hide_bar && configure_args+=(--hide-flow-bar)
"$configurer_target" "${configure_args[@]}"

if $system_setup; then
	info 'Granting input-device access to the helper (uinput + keyboards)'
	rule_tmp="$work_dir/70-wispr-flow-input.rules"
	cat > "$rule_tmp" <<'RULES'
# Wispr Flow Linux helper: injection plus push-to-talk on the active seat.
KERNEL=="uinput", SUBSYSTEM=="misc", OPTIONS+="static_node=uinput", TAG+="uaccess", GROUP="input", MODE="0660"
SUBSYSTEM=="input", KERNEL=="event*", ENV{ID_INPUT_KEYBOARD}=="1", TAG+="uaccess", GROUP="input", MODE="0660"
RULES
	sudo install -D -m 0644 "$rule_tmp" "$UDEV_RULE_PATH"
	sudo modprobe uinput
	sudo udevadm control --reload-rules
	sudo udevadm trigger --subsystem-match=misc --sysname-match=uinput || true
	sudo udevadm trigger --subsystem-match=input || true
	if ! id -nG "$install_user" | tr ' ' '\n' | grep -qx input; then
		sudo usermod -aG input "$install_user"
		sudo install -d -m 0755 "/var/lib/$PROJECT"
		sudo touch "/var/lib/$PROJECT/input-group-added-$install_user"
		printf '%s was added to the input group; log out and back in when the installer finishes.\n' "$install_user"
	fi
	[[ -e /dev/uinput ]] && sudo setfacl -m "u:${install_user}:rw" /dev/uinput || true
	for event in /dev/input/event*; do
		[[ -e $event ]] || continue
		if udevadm info --query=property --name="$event" 2>/dev/null \
			| grep -q '^ID_INPUT_KEYBOARD=1$'; then
			sudo setfacl -m "u:${install_user}:r" "$event" || true
		fi
	done
fi

if $hide_bar; then
	"$configurer_target" hyprland-rules on
fi

info 'Installation finished'
printf 'Wispr Flow:   %s\n' "$WISPR_FLOW_VERSION"
printf 'Install type: %s\n' "$package_type"
printf 'Executable:   %s\n' "$bin_target"
if [[ -r $install_root/usr/lib/wispr-flow/features ]]; then
	printf 'Bundle:       %s\n' "$(tr '\n' ' ' < "$install_root/usr/lib/wispr-flow/features")"
fi
if grep -q '^SKIPPED' "$install_root/usr/lib/wispr-flow/patch-report.txt" 2>/dev/null; then
	printf 'Skipped optional fixes (tolerant policy):\n'
	grep '^SKIPPED' "$install_root/usr/lib/wispr-flow/patch-report.txt" | sed 's/^/  /'
fi
cat <<'NEXT'

Next steps:
  wispr-flow --doctor              verify input access, helper, Omarchy integration
  wispr-flow                       start Flow, sign in, hold Ctrl+Shift to dictate
  wispr-flow --autostart on        start Flow with the Hyprland session
  wispr-flow --notetaker-audio on  let Notetaker record microphone + system audio

If the doctor cannot read /dev/input or /dev/uinput, log out and back in first.
NEXT
