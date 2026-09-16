# Changelog

All notable changes to the wispr-flow-omarchy support code are recorded here.
The bundled Wispr Flow version is pinned in `versions.env`.

## 1.1.4 - 2026-09-16

Validated end to end on the XPS 9320 (Omarchy 4.0.0.alpha) on 2026-09-16: a
Notetaker recording of a video with the user talking over it transcribed the
video as "Them" only and the user as "You" only. First release on `main`.

### Added

- `wispr-flow --notetaker-mic on|off|status`: an echo-cancelled microphone.
  With system audio working, the first transcript on Omarchy carried every
  sentence of a video twice, as "Them" from the loopback and as "You" from
  the laptop microphone hearing the speakers. The recorder asks Chromium
  for `echoCancellation` in mode `'all'`, which macOS and Windows satisfy with
  the OS's system-wide cancellation; Linux has none, and Wispr's own echo
  detector engaged only after a 28.8 s warm-up on that recording. The port
  builds the equivalent from PipeWire's echo-cancel module (WebRTC engine):
  a discard null sink, the canceller on the real microphone exposing
  `wispr_notetaker_mic`, and a loopback that feeds the default output's
  monitor into it as the reference. `on` makes the cancelled source the
  default input (Wispr Flow follows it), `off` restores the real microphone,
  the launcher recreates the modules after an audio restart, the doctor
  reports it, the uninstaller turns it off. Measured on the XPS 9320: raw
  microphone -56.4 dB mean / -40.5 dB peak with the speakers playing,
  cancelled -87.3 / -66.2 dB; quiet room -72.8 vs -90.3 dB.
- The reference must arrive shortly before the echo (47 dB cancellation at
  40 ms in a synthetic test, 14 dB at 120 ms). The loopback's `latency_msec`
  provides that lead; on this machine 170 (the speaker's 8 x 1024-frame ALSA
  buffer) cancelled 26 to 31 dB in every run, 140 and 200 almost nothing.
  The default is the default output's ALSA buffer length read from `pw-dump`
  (170 ms fallback), `WISPR_FLOW_AEC_DELAY_MS` overrides it.
- A gate after the canceller. Cancellation alone left a residual near
  -60 dB peak that the transcriber still decoded (garbled "You" copies; the
  recorder's echo detector saw 34 correlated windows and suppressed none).
  When `swh-plugins` is installed, `--notetaker-mic on` adds
  `module-ladspa-source` with `gate_1410` (threshold -55 dB on the signal's
  average level, `WISPR_FLOW_MIC_GATE_DB`; attack 5 ms, hold 250 ms, decay
  300 ms, range -90 dB) and makes `wispr_notetaker_mic_gated` the default
  input; below the threshold the source is real silence.
  `WISPR_FLOW_MIC_GATE=0` skips it; `status` reports the gate state or the
  missing plugin.
- Alignment self-test. The canceller's offset between microphone and
  reference is fixed when its streams start and varies from start to start:
  the same setting cancelled 28 dB or 2 dB in fresh instances, and the two
  recordings on this machine matched (1 correlated echo window in 17 versus
  34 in 77). `on` plays a 4 s speech-like signal, records the real
  microphone and the cancelled source together, and restarts the reference
  until the cancelled source is at least 12 dB quieter (four attempts).
  `status` shows the result; `WISPR_FLOW_AEC_VERIFY=0` skips it; the
  launcher's silent recreation marks the instance "not verified".

### Fixed

- Device labels: `pactl load-module` splits every argument on spaces, quotes
  included, so the Notetaker mix sink showed up as "Wispr" in device pickers,
  and pactl 17 has no `update-source-proplist` to repair it (the call was a
  silent no-op). Labels are now passed with non-breaking spaces, which pass
  through and render as spaces: "Wispr Notetaker Mix (microphone + system
  audio)" and "Wispr Notetaker Mic (echo cancelled)" appear in full.

### Changed

- `wispr-flow --version` reports wrapper 1.1.4.

## 1.1.3 - 2026-09-15

### Fixed

- The quiet monitor of 1.1.1 was Wispr Flow's doing: a 0.5 s poll of the
  sink's `monitorVolumes` showed the drop from 1.0 to 0.000482 (8%, which is
  20 of the 255 input levels Chromium's audio input path uses) 186 ms after
  the recorder logged `Loopback audio track acquired`, on every recording.
  `wispr-flow --system-audio fix` alone therefore held only until the next
  recording. The launcher now starts `wispr-flow-configure system-audio guard
  <pid>` with Flow: it follows `pactl subscribe`, restores the monitor to
  100% whenever it drops, and exits with the Electron process. One guard per
  session (`flock`), `WISPR_FLOW_MONITOR_GUARD=0` disables it, its lines go
  to `launcher.log`.

### Changed

- `linux-notetaker-fixes/windows-gate` confirmed on Omarchy 4.0.0.alpha with
  1.6.872: the Notetaker page shows recordings, upcoming meetings and
  settings after the rebuild.
- `wispr-flow --version` reports wrapper 1.1.3.

## 1.1.2 - 2026-09-15

### Fixed

- Flow Hub showed "Notetaker is coming soon! Our new meeting notetaker tool
  will become available on Windows soon." on Omarchy while the same 1.6.872
  client shows Notetaker on Windows. The hub hides Notetaker behind the
  Windows rollout, `blocked = isWindows && !flag("notetaker-windows")`. The
  port widens the renderer's `isWindows` to be true on Linux
  (port/linux-renderer-treat-as-windows) and PostHog evaluates the flag for a
  Linux device (`feature-flags-cache.json` held `"notetaker-windows":
  {"enabled": false}`), so Linux got the wall. New optional fix
  `linux-notetaker-fixes/windows-gate` (marker
  `WISPR_LINUX_NOTETAKER_WINDOWS_GATE`) ANDs the `isWindows` read inside that
  one hook with `"linux"!==window.electron?.platform?.os`; the flag, the main
  process and the server-side entitlement are untouched. Existing installs
  need `./install.sh` again.

### Changed

- `patches/linux-notetaker-fixes.sh` takes the hub renderer through `--hub`
  and reports `display-media` (main) and `windows-gate` (hub) separately;
  the assembler and `scripts/audit-bundle.sh` pass it, the assembler
  verifies the new marker under the strict policy. Fixtures carry the gate in
  the `new`, `dock` and `unknown` flavours (the last with renamed identifiers),
  a flag read without the gate under `--skip-optional`, and nothing in `old`;
  smoke covers applied, absent, skipped, idempotent and the assembler end to
  end.
- `wispr-flow --version` reports wrapper 1.1.2.

## 1.1.1 - 2026-09-15

First run on Omarchy hardware: Omarchy 4.0.0.alpha, Hyprland 0.56.2, PipeWire
1.6.8 with WirePlumber 0.5.17, kernel 7.2.3, Dell XPS 9320 (sof-soundwire),
Wispr Flow 1.6.872 built under the strict policy. All 24 Linux patches
applied, `wispr-flow --doctor` clean.

### Fixed

- Notetaker heard no system audio although the patched display-media handler
  installed and Chromium handed the recorder a live loopback track (the log
  showed `Loopback audio track acquired` followed by `sustained all-zero PCM
  detected` every 10 s). Cause on this machine: the default output's monitor
  source stood at 8% (`monitorVolumes` 0.000482 on the sink node), a volume no
  playback control shows and WirePlumber does not restore. `parecord` of the
  monitor measured -91 dB while a tone played; at 100% the same tone measured
  -26 dB. Both Notetaker paths read that monitor: Chromium's
  `PulseLoopbackManager` records `@DEFAULT_SINK@`'s monitor and the mix loops
  `@DEFAULT_MONITOR@`.

### Added

- `wispr-flow --system-audio check|fix`: reports the default output's monitor
  volume and mute state (exit 1 when it is below 100% or muted), or sets the
  monitor to 100% and unmutes it without touching playback. `--doctor` and
  `--notetaker-audio status` include the check, `--notetaker-audio on` warns,
  and the launcher writes the result to `launcher.log` on every start.

### Changed

- The launcher no longer passes `--enable-features=PulseaudioLoopbackForScreenShare`.
  Chromium's PulseAudio backend routes loopback device ids to
  `PulseLoopbackManager` without a feature check (the flag only gates Chrome's
  own picker UI), and the client's Sentry setup calls
  `app.commandLine.appendSwitch("enable-features", ...)`, which replaced the
  launcher's switch anyway. `WISPR_FLOW_NOTETAKER_LOOPBACK` still gates the
  display-media patch; the doctor line reads "the display-media handler is
  patched for Linux".
- `wispr-flow --version` reports wrapper 1.1.1.

## 1.1.0 - 2026-09-15

Pins Wispr Flow 1.6.872 (Notetaker for Windows, Electron 42.11.2), audited
offline against the official 1.6.774 and 1.6.872 clients. Not yet validated on
an Omarchy machine; see README "Status".

### Added

- `patches/linux-notetaker-fixes.sh`: the client never installs Electron's
  display-media request handler on Linux ("Skipping handler install on Linux
  (no system loopback path)"), so the meeting recorder's system-audio request
  was rejected before Chromium was asked and the documented Chromium loopback
  path could not work. The fix installs the handler when
  `WISPR_FLOW_NOTETAKER_LOOPBACK=1` (the launcher exports it next to the
  `PulseaudioLoopbackForScreenShare` flag) and answers Linux with the same
  `{audio:"loopback"}` Windows gets. Optional tier; reports `ABSENT` on
  bundles without Notetaker. Experimental until confirmed on hardware.
- `scripts/pin-latest.sh` resolves the newest release from Squirrel's
  `RELEASES` feed (the installer redirect no longer carries a version) and
  checks the download against the SHA-1 published there.
- The client's Electron version is read from its `package.json` (assembler,
  audit) or from the executable inside the nupkg (`pin-latest`); current
  releases ship no Squirrel `version` file, so the cross-check never ran.
  `features` records it as `client-electron=`.
- Fixture flavour `dock` (1.6.872 layout) and `--no-version-file`; CI now
  covers the dock-edge geometry, the Notetaker fix and both Electron sources.

### Changed

- `linux-runtime-fixes/status-bounds` and `/geometry` derive every identifier
  from the bundle: 1.6.872 re-minified the dock-edge geometry (`u` -> `d`,
  `{x:c,y:u,width:h}` -> `{x:c,y:l,width:d}`), which the old anchors hard-coded.
- Electron pinned to 42.11.2 (what 1.6.872 was built with; 1.6.774 was 42.5.1,
  not the 42.3.0 previously pinned - same ABI, so builds still worked).
- `wispr-flow --doctor` reports whether the display-media patch is in the
  installed build.

## 1.0.0 - 2026-09-15

Initial release, derived from [kukapu/whsprflow-arch](https://github.com/kukapu/whsprflow-arch)
at commit `cbb55c9` (Wispr Flow 1.6.774, Omarchy 4 Lua config).

### Added

- `versions.env` as the single pin file, plus `scripts/pin-latest.sh` to move to a
  newer Wispr Flow Windows release (resolves the latest installer, hashes the
  nupkg, detects the client's Electron version, audits every Linux patch).
- `scripts/audit-bundle.sh`: dry-run every Linux patch against a nupkg or an
  extracted app and report essential versus optional anchors.
- Patch policy: `strict` (default) requires every Linux fix; `tolerant` lets the
  optional Hyprland fixes be skipped and records them in `patch-report.txt`, so a
  new Wispr release installs the day it ships while anchors are re-audited.
- Omarchy-native Hyprland integration: managed rules and autostart live in
  `~/.local/state/omarchy/toggles/hypr/`, which Omarchy loads on every reload
  and `omarchy-refresh-hyprland` never overwrites. Plain Lua and classic conf
  entries remain supported. Rules are rolled back if Hyprland reports errors.
- Window rules for every Wispr Flow surface, including Notetaker reminder and
  recorder popups (floating, pinned).
- `wispr-flow --notetaker-audio on|off|status`: a PipeWire mix of the default
  microphone and the default output's monitor, so Notetaker records both sides
  of a meeting. The launcher recreates it after an audio restart and enables
  Chromium's system-audio loopback feature for the recorder.
- `wispr-flow --doctor` reports Omarchy version, Hyprland Lua support,
  integration mode, autostart, uwsm, Voxtype coexistence, PipeWire, the
  Notetaker mix, skipped optional patches and the bundle's detected features.
- Bundle feature detection written to `features` next to the runtime
  (renderers, Notetaker UI present or not, Electron version, policy).
- Electron cross-check between the Windows client and the Linux runtime; an
  Electron major bump is refused until the SQLite module is rebuilt.
- Reproducible helper build (`scripts/build-helper.sh`): build paths are
  remapped, so two builds with rustup's Rust 1.96.0 are byte-identical.
- Helper terminal-paste detection honours Omarchy's `terminal` window tag, so
  Omarchy TUIs (`org.omarchy.*`, `TUI.*`) receive Ctrl+Shift+V.
- Synthetic fixtures (`tests/fixtures/make-fixtures.sh`) and an end-to-end
  smoke test of the assembler without any proprietary input; GitHub Actions CI.

### Changed

- All user-facing text is English.
- Ownership markers, cache and state directories are named
  `wispr-flow-omarchy`; installs and config blocks from `whsprflow-arch` are
  still recognised and cleaned up.
- The three inline Hub fixes moved from the assembler into
  `patches/linux-hub-fixes.sh` with idempotency markers.
- The Hyprland status-window fixes derive minified identifiers from the bundle
  instead of hard-coding them per release.
- AUR packaging renamed to `wispr-flow-omarchy`, fetching the support code over
  git from this private repository.
