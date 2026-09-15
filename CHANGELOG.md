# Changelog

All notable changes to the wispr-flow-omarchy support code are recorded here.
The bundled Wispr Flow version is pinned in `versions.env`.

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
