# Moving to a newer Wispr Flow release

Every input of the build is pinned in `versions.env`. Wispr ships new Windows
releases often (the Notetaker release for Windows landed on 2026-09-15), and the
minified bundle changes shape each time. This is the procedure to follow the
release train without guessing.

## 1. Resolve, download, audit

Run this on the machine that installs Wispr Flow. It needs access to
`dl.wisprflow.ai` and `dl.wisprflow.com`:

```bash
scripts/pin-latest.sh
```

The script:

1. follows Wispr's `windows/latest` redirect and reads the version from the
   installer name (pass `--version X.Y.Z` to pick a specific release, or
   `--nupkg FILE` for a local `WisprFlow-X.Y.Z-full.nupkg`);
2. downloads `WisprFlow-X.Y.Z-full.nupkg` into `~/.cache/wispr-flow-omarchy/`
   and prints its SHA-256;
3. reads the Electron version the Windows client was built with and, if it
   changed, fetches the matching Linux Electron checksum from GitHub;
4. runs `scripts/audit-bundle.sh` against the new bundle.

Nothing is written until you add `--write`.

## 2. Read the audit

```text
Patch anchors
  ESSENTIAL port/helper-resolver                     OK
  ESSENTIAL helper-env-fallback (>= 1.6.774 shape)   OK
  ...
  OPTIONAL  linux-runtime-fixes/start-sound          FAILED (could not derive the Hub sound channel ...)
Summary: 0 essential failure(s), 1 optional failure(s)
```

- **ESSENTIAL** rows make Linux work at all: helper path, helper environment,
  the macOS Applications-folder gate, cold-start login callback, the win32
  renderer chrome and platform booleans. If one fails, the release cannot be
  built. Re-audit the anchor in the port's patch script (see the
  wispr-flow-linux `docs/learnings/patching-minified-js.md`) or wait for the
  port to update, then bump `PORT_COMMIT`.
- **OPTIONAL** rows are Hyprland comfort: transient recording indicator, local
  dictation sounds, indicator geometry, Hub focus, warm login callback, the
  meeting recorder's frameless window. When one fails you have two choices:
  - install now with `./install.sh --patch-policy tolerant`; the skipped fixes
    are listed in `patch-report.txt` next to the runtime and by
    `wispr-flow --doctor`, and the corresponding `WISPR_FLOW_*` switches simply
    have no effect;
  - or re-audit the anchor in `patches/linux-runtime-fixes.sh` or
    `patches/linux-hub-fixes.sh`, then run `tests/smoke.sh` and rebuild under the
    strict policy.

## 3. Write the pins

```bash
scripts/pin-latest.sh --version X.Y.Z --write
tests/smoke.sh
./install.sh            # add --patch-policy tolerant if optional fixes were skipped
wispr-flow --doctor
```

Then update `packaging/aur/PKGBUILD` (`pkgver`, `sha256sums` for the nupkg and,
if changed, Electron), regenerate `.SRCINFO` with `scripts/gen-srcinfo.sh`,
record the bump in `CHANGELOG.md`, and commit. `tests/smoke.sh` fails when the
PKGBUILD and `versions.env` disagree.

## Electron major bump

`pin-latest.sh` stops when the Windows client moved to a new Electron major.
The pinned `node_sqlite3` module is compiled for one Electron ABI (146 for
Electron 42) and would fail to load. Rebuild it first with the port's
`scripts/rebuild-native-modules.sh` (or wait for a new
`wispr-flow-linux/native-modules` release), host the module, update
`SQLITE_RELEASE_BASE_URL` and `SQLITE_SHA256`, and rerun with
`--allow-electron-change`.

## Re-auditing a moved anchor

1. Extract the new bundle without installing anything:

   ```bash
   scripts/audit-bundle.sh --nupkg ~/.cache/wispr-flow-omarchy/WisprFlow-X.Y.Z-full.nupkg --keep /tmp/wispr-audit
   ```

2. Beautify `/tmp/wispr-audit/.webpack/main/index.js` with
   `prettier --parser babel --ignore-path /dev/null` and search for the developer
   string named in the failure (for example `Showing status window`).
3. Adjust the regex in the patch script. Anchor on strings and syntactic shape,
   derive identifiers from the match, never hard-code a minified name.
4. Add the new shape to `tests/fixtures/make-fixtures.sh` so CI keeps covering
   it, run `tests/smoke.sh`, rebuild.

## Updating the helper

The helper binary in `assets/` is built by `scripts/build-helper.sh` from the
pinned `HELPER_COMMIT` plus `patches/helper/`. To change either:

```bash
rustup toolchain install 1.96.0 --component rustfmt --component clippy
RUSTUP_TOOLCHAIN=1.96.0 scripts/build-helper.sh --allow-mismatch /tmp/helper
sha256sum /tmp/helper        # put this into versions.env HELPER_SHA256
cp /tmp/helper assets/wispr-flow-linux-helper-x86_64
```

Update the `*_SHA256` constants at the top of `build-helper.sh` when a patch
file changes, and the `_helper_sha256` in the PKGBUILD. The build is
reproducible with rustup's toolchain: two builds in different directories give
the same hash.
