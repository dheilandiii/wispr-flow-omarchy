#!/usr/bin/env bash
# uninstall.sh: remove a wispr-flow-omarchy installation (and the legacy
# whsprflow-arch layout it derives from) cleanly.
#
# Stops the exact processes of each owned installation, removes the managed
# Hyprland rules and autostart, the Notetaker audio mix, the udev rule and the
# ACLs, then the files. Account data in ~/.config/Wispr Flow is kept unless
# --purge is given.

set -Eeuo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$script_dir/scripts/lib/common.sh"

case "${1:-}" in
	'') purge=false ;;
	--purge) purge=true ;;
	-h|--help) printf 'Usage: %s [--purge]\n' "$0"; exit 0 ;;
	*) printf 'Usage: %s [--purge]\n' "$0" >&2; exit 2 ;;
esac

data_home="${XDG_DATA_HOME:-$HOME/.local/share}"
user_bin="$HOME/.local/bin/wispr-flow"
user_configurer="$HOME/.local/bin/wispr-flow-configure"
user_root="${WISPR_FLOW_INSTALL_ROOT:-$data_home/$PROJECT/app}"
user_root="$(realpath -m -- "$user_root")"
legacy_user_root="$(realpath -m -- "$data_home/$LEGACY_PROJECT/app")"
install_user="$(id -un)"
group_markers=("/var/lib/$PROJECT/input-group-added-$install_user" "/var/lib/$LEGACY_PROJECT/input-group-added-$install_user")
cleanup_failed=false
group_removed=false

root_owned() {
	local root="$1" allow_legacy="$2"
	[[ -e $root ]] || return 0
	[[ $root == /* && $root != / && $root != "$HOME" && ! -L $root ]] || return 1
	root_marked "$root" && return 0
	$allow_legacy
}

stop_install() {
	local root="$1"
	[[ -x $root/usr/lib/wispr-flow/wispr-flow ]] || return 0
	WISPR_FLOW_INSTALL_ROOT="$root" "$script_dir/bin/wispr-flow" --stop
}

system_owned=false
user_owned=false
wrapper_owned /usr/local/bin/wispr-flow && system_owned=true
wrapper_owned "$user_bin" && user_owned=true

# Stop every owned installation before removing executable paths. If two are
# active, the first pass may still see the other's virtual keyboard; retry once
# after both process trees have received the shutdown request.
user_roots=()
[[ -d $user_root ]] && user_roots+=("$user_root")
[[ -d $legacy_user_root && $legacy_user_root != "$user_root" ]] && user_roots+=("$legacy_user_root")
stop_retry=false
if $system_owned && ! stop_install /opt/wispr-flow; then
	stop_retry=true
fi
if $user_owned; then
	for root in "${user_roots[@]}"; do
		[[ $root != /opt/wispr-flow ]] || continue
		stop_install "$root" || stop_retry=true
	done
fi
if $stop_retry; then
	if $system_owned; then
		stop_install /opt/wispr-flow || die 'Could not stop the system installation.'
	fi
	if $user_owned; then
		for root in "${user_roots[@]}"; do
			[[ $root != /opt/wispr-flow ]] || continue
			stop_install "$root" || die "Could not stop the user installation at $root."
		done
	fi
fi

configurer="$script_dir/bin/wispr-flow-configure"
if [[ -x $configurer ]]; then
	if ! WISPR_FLOW_SKIP_HYPR_RELOAD=1 "$configurer" autostart off; then
		warn 'Could not remove the managed autostart.'
		cleanup_failed=true
	fi
	if ! "$configurer" hyprland-rules off; then
		warn 'Could not remove the managed Hyprland rules.'
		cleanup_failed=true
	fi
	"$configurer" notetaker-audio off >/dev/null 2>&1 || true
	"$configurer" notetaker-mic off >/dev/null 2>&1 || true
else
	warn "Missing $configurer; Hyprland integration was not cleaned up."
	cleanup_failed=true
fi

if $system_owned; then
	root_owned /opt/wispr-flow true \
		|| die "/opt/wispr-flow is not verifiably owned by $PROJECT."
	sudo rm -f /usr/local/bin/wispr-flow /usr/local/bin/wispr-flow-configure
	sudo rm -rf /opt/wispr-flow
fi

if $user_owned; then
	allow_legacy=true
	[[ -n ${WISPR_FLOW_INSTALL_ROOT:-} ]] && allow_legacy=false
	for root in "${user_roots[@]}"; do
		root_owned "$root" "$allow_legacy" \
			|| die "$root is not verifiably owned by $PROJECT."
		rm -rf "$root"
	done
	rm -f "$user_bin" "$user_configurer"
fi

rm -f "$data_home/applications/wispr-flow.desktop"
rm -f "$data_home/icons/hicolor/scalable/apps/wispr-flow.svg"
have update-desktop-database && update-desktop-database "$data_home/applications"

rule_owned=false
if [[ -f $UDEV_RULE_PATH ]]; then
	if grep -qxF "$UDEV_RULE_HEADER" "$UDEV_RULE_PATH"; then
		rule_owned=true
	else
		warn "$UDEV_RULE_PATH does not match the managed rule; leaving it in place."
		cleanup_failed=true
	fi
fi

marker_present=false
for marker in "${group_markers[@]}"; do
	[[ -f $marker ]] && marker_present=true
done

if $rule_owned || $marker_present; then
	$rule_owned && sudo rm -f "$UDEV_RULE_PATH"
	sudo udevadm control --reload-rules
	sudo udevadm trigger --subsystem-match=misc --sysname-match=uinput || true
	sudo udevadm trigger --subsystem-match=input || true
	[[ -e /dev/uinput ]] && sudo setfacl -x "u:$install_user" /dev/uinput 2>/dev/null || true
	for event in /dev/input/event*; do
		[[ -e $event ]] || continue
		sudo setfacl -x "u:$install_user" "$event" 2>/dev/null || true
	done
	for marker in "${group_markers[@]}"; do
		[[ -f $marker ]] || continue
		if ! $group_removed; then
			sudo gpasswd -d "$install_user" input
			group_removed=true
			printf '%s was removed from the input group; log out to revoke the current membership.\n' "$install_user"
		fi
		sudo rm -f "$marker"
	done
	sudo rmdir "/var/lib/$PROJECT" "/var/lib/$LEGACY_PROJECT" 2>/dev/null || true
fi

if $purge; then
	rm -rf "${XDG_CONFIG_HOME:-$HOME/.config}/Wispr Flow"
	rm -rf "${XDG_STATE_HOME:-$HOME/.local/state}/$PROJECT"
	rm -rf "${XDG_CACHE_HOME:-$HOME/.cache}/$PROJECT" "${XDG_CACHE_HOME:-$HOME/.cache}/$LEGACY_PROJECT"
	rm -rf "${XDG_CACHE_HOME:-$HOME/.cache}/wispr-flow"
fi

printf 'Wispr Flow uninstalled. The udev rule and the managed ACLs were removed.\n'
if ! $group_removed && id -nG "$install_user" | tr ' ' '\n' | grep -qx input; then
	printf 'A pre-existing or unrecorded input group membership was kept.\n'
fi
printf 'Use --purge to also delete the local account, preferences, logs and downloads.\n'
if $cleanup_failed; then
	exit 1
fi
