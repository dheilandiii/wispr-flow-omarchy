#!/usr/bin/env bash
# helper-env-fallback.sh: propagate the session environment to the Linux helper
# when the port's helper-env.sh anchor is gone.
#
# Wispr Flow >= 1.6.774 factored the helper spawn environment out of the spawn
# call:   env:{sentryDSN,...}   became   env:N()   with
#         N=(e=a.app.isPackaged)=>({sentryDSN:f.kL,...}).
# The port's helper-env.sh anchors on `env:{` and fails with "expected exactly 1
# helper-spawn env anchor, found 0". This fallback anchors on the stable
# telemetry nucleus inside N() (unminified property names and string literals,
# one occurrence in 1.6.447 and 1.6.774 alike) and inserts the same
# `...process.env` spread with the same WISPR_LINUX_HELPER_ENV marker, so the
# helper inherits WAYLAND_DISPLAY / DISPLAY / XDG_RUNTIME_DIR and picks the
# Wayland backend instead of the no-op stub.
#
# Usage: helper-env-fallback.sh <.webpack/main/index.js>

set -Eeuo pipefail

BUNDLE="${1:-}"
[[ -f $BUNDLE ]] || { printf 'Usage: %s <.webpack/main/index.js>\n' "$0" >&2; exit 2; }

ENV_MARKER="WISPR_LINUX_HELPER_ENV"
if grep -qF "$ENV_MARKER" "$BUNDLE"; then
	echo "Already patched ($ENV_MARKER present in $BUNDLE); nothing to do."
	exit 0
fi

if [[ ! -f "$BUNDLE.orig" ]]; then
	cp -p "$BUNDLE" "$BUNDLE.orig"
	echo "Backup written: $BUNDLE.orig"
fi

python3 - "$BUNDLE" "$ENV_MARKER" <<'PY'
import io
import re
import sys

path, marker = sys.argv[1], sys.argv[2]
with io.open(path, "r", encoding="utf-8", errors="surrogateescape") as f:
    data = f.read()

# The telemetry nucleus of the helper env factory: only string literals and
# preserved property names, so it survives re-minification. The module alias
# (`f` in 1.6.774) is derived from the match rather than hard-coded.
anchor = re.compile(
    r'sentryDSN:(?P<mod>[\w$]+)\.[\w$]+,environment:(?P=mod)\.[\w$]+,'
    r'segmentWriteKey:(?P=mod)\.[\w$]+,postHogProjectKey:(?P=mod)\.[\w$]+,'
    r'sentryLocalDebug:(?P=mod)\.[\w$]+\?"true":""'
)
matches = list(anchor.finditer(data))
if len(matches) != 1:
    sys.exit(f"ERROR: expected exactly 1 helper-env factory anchor, found {len(matches)}.")

m = matches[0]
window = data[max(0, m.start() - 200): m.start()]
if "...process.env" in window:
    print("The helper env already spreads process.env; nothing to do.")
    sys.exit(0)

data = data[: m.start()] + f"/*{marker}*/...process.env," + data[m.start():]
with io.open(path, "w", encoding="utf-8", errors="surrogateescape") as f:
    f.write(data)
print(f"Patched: spread process.env into the helper env factory (module alias {m.group('mod')!r}).")
PY

if ! grep -qF "$ENV_MARKER" "$BUNDLE"; then
	echo "ERROR: post-patch verification failed (marker not found); restoring backup." >&2
	cp -p "$BUNDLE.orig" "$BUNDLE"
	exit 1
fi

if command -v node >/dev/null 2>&1; then
	if ! node --check "$BUNDLE"; then
		echo "ERROR: node --check failed on the patched bundle; restoring backup." >&2
		cp -p "$BUNDLE.orig" "$BUNDLE"
		exit 1
	fi
	echo "node --check OK"
fi
echo "OK: the helper now inherits the session environment ($BUNDLE)"
