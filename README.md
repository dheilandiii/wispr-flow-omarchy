# Wispr Flow for Omarchy

Runs the official [Wispr Flow](https://wisprflow.ai) desktop client, including
Notetaker, natively on [Omarchy](https://omarchy.org) (Arch Linux + Hyprland).
It is not a Whisper reimplementation and it does not use Wine: the Electron
client, your account, the Pro plan and Wispr's cloud transcription stay as they
are. Only the Windows integration layer is replaced by an open-source Linux
helper, and a handful of platform gates in the client are patched so Linux
takes the Windows code paths.

This repository builds on [kukapu/whsprflow-arch](https://github.com/kukapu/whsprflow-arch)
and the [wispr-flow-linux](https://github.com/wispr-flow-linux/wispr-flow-linux)
port. Wispr does not publish or support a Linux version; this is a community
port and can break with a future release of the service.

The repository never contains the proprietary client. `install.sh` downloads it
from Wispr's CDN and verifies its SHA-256 against `versions.env`.

## Status

| Item | State |
| --- | --- |
| Pinned Wispr Flow | 1.6.872 (`versions.env`); all 24 Linux patches apply and `wispr-flow --doctor` passes on Omarchy 4.0.0.alpha, Hyprland 0.56.2 |
| Notetaker for Windows | released 2026-09-15, in the pinned client; Linux system audio via Chromium loopback or the Notetaker mix, both from the default output's monitor (`wispr-flow --system-audio check`, see below) |
| Omarchy | 4.0.x, Hyprland >= 0.55 Lua config; classic `hyprland.conf` still supported |
| Architecture | x86_64 only |
| Helper binary | reproducible build from a pinned commit, Rust 1.96.0, see `scripts/build-helper.sh` |
| Electron | 42.11.2, the version the pinned client was built with (read from its `package.json`) |

## Install on Omarchy

```bash
git clone https://github.com/dheilandiii/wispr-flow-omarchy.git
cd wispr-flow-omarchy
tests/smoke.sh              # offline self-check of the scripts, ends with "Smoke tests OK"
scripts/pin-latest.sh       # optional: audit the newest Windows release (Notetaker) and pin it with --write
./install.sh                # installs to /opt/wispr-flow, asks for sudo where needed
```

Then, still as your desktop user:

```bash
wispr-flow --doctor         # every line should be PASS or an explained WARN
wispr-flow                  # sign in; the browser returns through the wispr-flow: callback
```

Hold **Ctrl+Shift** to dictate. If the doctor cannot read `/dev/uinput` or
`/dev/input`, log out and back in once: the installer added you to the `input`
group.

Optional:

```bash
wispr-flow --autostart on         # start Flow with the Hyprland session (uwsm-managed)
wispr-flow --notetaker-audio on   # record meetings with microphone + system audio
```

Need it faster? `./install.sh --patch-policy tolerant` builds even when a new
Wispr release moved the anchors of the optional Hyprland fixes; the doctor
lists what was skipped.

## Notetaker

Notetaker lives in Flow Hub. On Linux the recorder gets the microphone through
PipeWire like any app; the other side of the call needs system audio, which
this port provides two ways, and both read the monitor of the default output.
Chromium's system-audio loopback: the client skips Electron's display-media
handler on Linux, so `patches/linux-notetaker-fixes.sh` installs it and
Chromium records the default sink's monitor (`WISPR_FLOW_NOTETAKER_LOOPBACK=0`
turns it off). Or a PipeWire virtual source, **Wispr Notetaker Mix**, that
combines your microphone with that monitor: `wispr-flow --notetaker-audio on`,
then pick it as the microphone in Flow while recording. Either way the monitor
must be at full volume: `wispr-flow --system-audio check` tells you and
`wispr-flow --system-audio fix` sets it. The first recording on Omarchy found
it at 8% and heard nothing. Meeting auto-detection is limited on Wayland (no
browser URLs reach the helper), so start recordings from Flow Hub. Details and
troubleshooting: [docs/NOTETAKER.md](docs/NOTETAKER.md).

## What the Omarchy integration does

- **Hyprland rules that survive Omarchy updates.** Managed rules go to
  `~/.local/state/omarchy/toggles/hypr/wispr-flow.lua`. Omarchy loads every file
  in that directory on each reload and `omarchy-refresh-hyprland` never
  overwrites it, so your `hyprland.lua` stays untouched. On plain Hyprland the
  rules are attached to `hyprland.lua` (Lua) or `hyprland.conf` (classic).
  Rules are rolled back automatically if Hyprland reports a config error.
- **Windows behave.** Every Wispr Flow window floats; Flow Hub is centered with
  a remembered size; the dictation pill never takes focus; Notetaker reminders
  and the recorder pill are pinned across workspaces.
- **Native Wayland by default.** The persistent Flow Bar is hidden (it leaves an
  invisible click-swallowing surface on Hyprland) and replaced by a transient
  recording indicator on native Wayland. `wispr-flow --flow-bar on` brings the
  bar back under XWayland.
- **Terminals get the right paste chord.** The helper sends Ctrl+Shift+V when
  the focused window carries Omarchy's `terminal` tag (Alacritty, kitty,
  Ghostty, foot, Omarchy's own TUI windows) and Ctrl+V everywhere else.
- **uwsm autostart.** `--autostart on` registers a `hyprland.start` hook that
  runs `uwsm-app -- wispr-flow --background`.
- **Coexists with Voxtype.** Omarchy's Voxtype keeps F9 and Super+Ctrl+X; Wispr
  uses Ctrl+Shift.
- **Doctor knows Omarchy.** `wispr-flow --doctor` reports the Omarchy version,
  Hyprland Lua support, integration mode, autostart, uwsm, PipeWire, the
  Notetaker mix, the default output's monitor volume, skipped optional patches
  and the installed bundle's features.

A keybinding for Flow Hub is one line in `~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + ALT + W", "Wispr Flow", "wispr-flow --show")
```

## Commands

```text
wispr-flow                        start (or focus) Flow
wispr-flow --setup                per-user setup: config, login callback, Hyprland rules
wispr-flow --doctor               diagnostics
wispr-flow --show | --hide        Flow Hub to the current workspace / to special:wispr-flow
wispr-flow --background           start Flow ready without a visible Hub
wispr-flow --stop                 clean shutdown of this installation only
wispr-flow --reset-input          recover a stuck virtual keyboard
wispr-flow --autostart on|off|status
wispr-flow --hyprland-rules on|off|check
wispr-flow --notetaker-audio on|off|status
wispr-flow --system-audio check|fix   default output's monitor volume, read by both Notetaker paths
wispr-flow --flow-bar on|off      persistent bar (XWayland) vs transient indicator
wispr-flow --fix-shortcut         reset push-to-talk to Ctrl+Shift
wispr-flow --version | --logs | --help
```

Environment overrides: `WISPR_FLOW_BACKEND=auto|wayland|x11`,
`WISPR_FLOW_NOTETAKER_LOOPBACK=0`, `WISPR_FLOW_TRANSIENT_STATUS_WINDOW=0`,
`WISPR_FLOW_STATUS_ZOOM`, `WISPR_FLOW_STATUS_Y`, `WISPR_FLOW_STATUS_W`,
`WISPR_FLOW_STATUS_H`, `WISPR_FLOW_STATUS_CLICKABLE=1`, `WISPR_DISABLE_GPU=1`.

## Following Wispr Flow releases

`versions.env` pins the client, Electron, the port commit, the helper and the
SQLite module. `scripts/pin-latest.sh` resolves the newest Windows release from
Wispr's Squirrel `RELEASES` feed, hashes it, reads the Electron version the
client was built with and dry-runs every Linux patch against it before touching
the pins. Patches are tiered: the essential platform
patches must always apply; the optional Hyprland fixes can be skipped under the
tolerant policy and are recorded in `patch-report.txt`. The procedure, and what
to do when an anchor moves or Electron changes major, is in
[docs/UPGRADING.md](docs/UPGRADING.md).

## How the build works

`install.sh` downloads `WisprFlow-<version>-full.nupkg` (the official Windows
package), Electron for Linux and a prebuilt `node_sqlite3` module, verifies all
three, fetches the pinned wispr-flow-linux port and runs
`scripts/assemble-app.sh`, which:

1. extracts `app.asar` and checks the version inside it and the Electron version
   the client was built with;
2. applies the port's platform patches (helper path, helper environment,
   macOS gate, cold-start deep link, renderer chrome and platform booleans);
3. applies this repository's Hyprland fixes (`patches/`): Hub focus and warm
   deep link, transient status indicator, local dictation sounds, indicator
   geometry, and the Notetaker display-media handler for Linux;
4. drops the Windows-only native modules, installs the Linux SQLite module and
   the helper, verifies every patch marker in the packed asar and writes
   `features` and `patch-report.txt` next to the runtime.

The helper (`assets/wispr-flow-linux-helper-x86_64`) is the
[wispr-flow-linux/helper](https://github.com/wispr-flow-linux/helper) at a
pinned commit with two patches: a uinput chord that never leaves a virtual
modifier pressed, and terminal detection that honours Omarchy's terminal tag.
`scripts/build-helper.sh` rebuilds it reproducibly.

## AUR packaging

`packaging/aur/` carries a PKGBUILD named `wispr-flow-omarchy` that fetches the
support code from this private repository over git (your git credentials must
have read access). Do not install it on a machine that used `./install.sh`
without running `./uninstall.sh` first; the two layouts must not overlap. The
package conflicts with the unrelated `wispr-flow-appimage` AUR package.

## Security notes

The helper writes to `/dev/uinput` to type text and reads keyboard event
devices for push-to-talk. The udev rule limits reads to devices udev marks as
keyboards and scopes access to the active seat, but any process running as your
user could use the same access. `~/.config/Wispr Flow/` holds your session; do
not share it or `~/.cache/wispr-flow/launcher.log`.

## Uninstall

```bash
./uninstall.sh          # keeps ~/.config/Wispr Flow
./uninstall.sh --purge  # also removes account data, preferences, caches
```

## Tests

`tests/smoke.sh` runs offline: syntax, pins, the configurer in all three
Hyprland modes, the launcher, every patch script against synthetic bundles
(`tests/fixtures/make-fixtures.sh`), and, given a wispr-flow-linux checkout in
`WISPR_FLOW_PORT_DIR`, the assembler end to end. GitHub Actions runs it on Arch
and Ubuntu.

## Licenses

Support code: MIT (this repository) and 0BSD (the parts derived from
whsprflow-arch), see `REUSE.toml`. Helper and its patches: Unlicense. Electron:
MIT. The Wispr Flow client is proprietary and stays under Wispr's terms; this
repository grants no rights to it.
