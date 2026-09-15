#!/usr/bin/env bash
# build-helper.sh: reproduce assets/wispr-flow-linux-helper-x86_64 from source.
#
# Clones the pinned wispr-flow-linux/helper commit, applies the two patches in
# patches/helper/, runs fmt/test/clippy, builds a release binary with the pinned
# Rust toolchain and refuses to write the result unless its SHA-256 matches
# HELPER_SHA256 in versions.env. Run it under `rustup run <version>` or with
# RUSTUP_TOOLCHAIN set when the pinned toolchain is not the default.
#
# Usage: build-helper.sh [--allow-mismatch] [OUTPUT]
#   OUTPUT            default: assets/wispr-flow-linux-helper-x86_64
#   --allow-mismatch  write OUTPUT even when the SHA-256 differs from the pin
#                     and print the new hash (used when re-pinning the helper)
#
# Reproducibility: source and registry paths are remapped to fixed prefixes,
# SOURCE_DATE_EPOCH is fixed and incremental compilation is off, so two builds
# with the same rustup toolchain produce byte-identical binaries in any
# directory. A distribution-packaged rustc of the same version can still differ.

set -Eeuo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$root/scripts/lib/common.sh"
load_versions

# Content hashes of the helper sources before and after our patches. They pin
# the exact upstream files the patches were written against.
readonly UPSTREAM_UINPUT_SHA256='ff2e65111f0a7f5b54af9e99bee8e8484011d35a15c8374fab00e956a59afba1'
readonly PATCHED_UINPUT_SHA256='e0ac469f0d3c6227802d7beb364b16b3b52f12b6838df35bae7e9950ab5cc919'
readonly UPSTREAM_WAYLAND_SHA256='04a5521656b3ba5711518add58aa82d868df3f118f3ecf3cc984b60423da379f'
readonly TERMINAL_PATCH_SHA256='0dce84fba5a41a0fa1692654db706797accaba1530d4b69f1f40f39451865400'
readonly PATCHED_WAYLAND_SHA256='689ef5341e8f04973897eeda6e8a72028ddb36c5c787f965d29dedd628846bab'

allow_mismatch=false
output=''
while (($#)); do
	case "$1" in
		--allow-mismatch) allow_mismatch=true ;;
		-h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
		*) output="$1" ;;
	esac
	shift
done
output="${output:-$root/assets/wispr-flow-linux-helper-x86_64}"

for command in cargo file git patch rustc sha256sum; do
	have "$command" || die "Missing '$command'."
done

actual_rustc="$(rustc --version | cut -d' ' -f2)"
[[ $actual_rustc == "$HELPER_RUSTC_VERSION" ]] \
	|| die "rustc $HELPER_RUSTC_VERSION is required for a reproducible build; found $actual_rustc. Try: RUSTUP_TOOLCHAIN=$HELPER_RUSTC_VERSION $0"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

info "Cloning helper at $HELPER_COMMIT"
git clone --quiet --no-checkout "$HELPER_REPO" "$work/helper"
git -C "$work/helper" checkout --quiet "$HELPER_COMMIT"
[[ $(git -C "$work/helper" rev-parse HEAD) == "$HELPER_COMMIT" ]] \
	|| die 'The helper checkout does not match the pinned commit.'

info 'Applying the uinput and terminal-paste patches'
upstream="$work/helper/src/backend/uinput.rs"
patch="$root/patches/helper/uinput.rs"
sha_ok "$upstream" "$UPSTREAM_UINPUT_SHA256" || die 'Upstream uinput.rs does not match the expected content.'
sha_ok "$patch" "$PATCHED_UINPUT_SHA256" || die 'patches/helper/uinput.rs does not match its pinned hash.'
install -m 0644 "$patch" "$upstream"

wayland="$work/helper/src/backend/wayland.rs"
terminal_patch="$root/patches/helper/terminal-paste.patch"
sha_ok "$wayland" "$UPSTREAM_WAYLAND_SHA256" || die 'Upstream wayland.rs does not match the expected content.'
sha_ok "$terminal_patch" "$TERMINAL_PATCH_SHA256" || die 'patches/helper/terminal-paste.patch does not match its pinned hash.'
patch --batch --forward --fuzz=0 -d "$work/helper" -p1 < "$terminal_patch"
sha_ok "$wayland" "$PATCHED_WAYLAND_SHA256" || die 'wayland.rs does not match the expected patched content.'

unset CARGO_ENCODED_RUSTFLAGS
cargo_home="${CARGO_HOME:-$HOME/.cargo}"
export RUSTFLAGS="--remap-path-prefix=$work=/build --remap-path-prefix=$cargo_home=/cargo"
export CARGO_INCREMENTAL=0
export CARGO_TARGET_DIR="$work/target"
export SOURCE_DATE_EPOCH=1781205638

info 'fmt, test, clippy, release build'
cargo fmt --check --manifest-path "$work/helper/Cargo.toml"
cargo test --locked --manifest-path "$work/helper/Cargo.toml"
cargo clippy --locked --all-targets --manifest-path "$work/helper/Cargo.toml" -- -D warnings
cargo build --release --locked --manifest-path "$work/helper/Cargo.toml"

built="$work/target/release/wispr-flow-linux-helper"
file "$built" | grep -q 'ELF 64-bit.*x86-64' || die 'The built helper is not a Linux x86_64 ELF binary.'
actual_sha="$(sha256sum "$built" | cut -d' ' -f1)"
if [[ $actual_sha != "$HELPER_SHA256" ]]; then
	if $allow_mismatch; then
		warn "The helper hash differs from the pin: pinned $HELPER_SHA256, built $actual_sha (writing anyway)."
	else
		die "The helper did not reproduce: expected $HELPER_SHA256, got $actual_sha."
	fi
fi

mkdir -p "$(dirname "$output")"
install -m 0755 "$built" "$output"
printf 'Helper reproduced: %s\nSHA-256: %s\n' "$output" "$actual_sha"
