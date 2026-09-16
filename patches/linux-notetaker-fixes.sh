#!/usr/bin/env bash
# linux-notetaker-fixes.sh: main-bundle fixes for Notetaker on Linux.
#
#   display-media   The meeting recorder captures the other side of a call with
#                   getDisplayMedia({audio:true}), which Electron only serves
#                   when the main process installed a display-media request
#                   handler. The client installs one on macOS and Windows and
#                   logs "Skipping handler install on Linux (no system loopback
#                   path)" on Linux, so the recorder's system-audio request is
#                   rejected before Chromium is even asked. Chromium's PulseAudio
#                   backend serves the request on Linux by recording the monitor
#                   of the default output (no feature flag involved; the monitor
#                   must not be turned down, see wispr-flow --system-audio). This
#                   fix keeps the skip unless WISPR_FLOW_NOTETAKER_LOOPBACK=1 is
#                   set (the launcher exports it) and answers Linux requests with
#                   {audio:"loopback"}, the same answer Windows gets. Two
#                   coordinated sites, applied together or not at all.
#
# A bundle without a display-media handler (Wispr Flow < Notetaker) reports
# ABSENT, which satisfies both policies. Policy: strict (default) fails when a
# present anchor cannot be patched; tolerant reports and continues. Idempotent
# through inline markers.
#
# Usage: linux-notetaker-fixes.sh <.webpack/main/index.js> [--policy strict|tolerant] [--report FILE]

set -Eeuo pipefail

bundle=''
policy="${WISPR_FLOW_PATCH_POLICY:-strict}"
report=''
while (($#)); do
	case "$1" in
		--policy) policy="${2:-}"; shift ;;
		--report) report="${2:-}"; shift ;;
		*) bundle="$1" ;;
	esac
	shift
done
[[ -f $bundle ]] || { printf 'Usage: %s <.webpack/main/index.js> [--policy strict|tolerant] [--report FILE]\n' "$0" >&2; exit 2; }
[[ $policy == strict || $policy == tolerant ]] || { printf 'ERROR: policy must be strict or tolerant.\n' >&2; exit 2; }

python3 - "$bundle" "$policy" "${report:-/dev/null}" <<'PY'
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
policy = sys.argv[2]
report_path = sys.argv[3]
data = path.read_text(encoding="utf-8", errors="surrogateescape")

ENV = 'process.env.WISPR_FLOW_NOTETAKER_LOOPBACK'
GATE_MARK = "WISPR_LINUX_NOTETAKER_LOOPBACK_GATE"
BRANCH_MARK = "WISPR_LINUX_NOTETAKER_LOOPBACK_BRANCH"

# Site 1: the Linux early-out before the handler is installed. The logger and
# the "installed" flag are derived from the match.
GATE = re.compile(
    r'if\("linux"===process\.platform\)return '
    r'(?P<log>[\w$]+\(\)\.info\("\[MeetingDisplayMedia\] Skipping handler install on Linux[^"]*"\)),'
    r'void\((?P<flag>[\w$]+)=!0\);'
)
# Site 2: the handler itself. Linux answers with the Windows loopback source;
# the macOS/Windows branches that follow are untouched.
BRANCH = re.compile(r'setDisplayMediaRequestHandler\(\(e,t\)=>\{')

name = "display-media"
status, detail = "", ""
gate_done, branch_done = GATE_MARK in data, BRANCH_MARK in data
if gate_done and branch_done:
    status = "ALREADY"
elif gate_done or branch_done:
    status, detail = "SKIPPED", "bundle is partially patched (one of two markers present)"
elif "setDisplayMediaRequestHandler(" not in data:
    status, detail = "ABSENT", "bundle has no display-media handler (no Notetaker)"
else:
    gates = list(GATE.finditer(data))
    branches = list(BRANCH.finditer(data))
    if len(gates) != 1 or len(branches) != 1:
        status, detail = "SKIPPED", f"expected one Linux skip and one handler anchor, found {len(gates)} and {len(branches)}"
    else:
        g, b = gates[0], branches[0]
        gate_repl = (
            f'if("linux"===process.platform&&"1"!=={ENV}/*{GATE_MARK}*/)return '
            f'{g.group("log")},void({g.group("flag")}=!0);'
        )
        branch_repl = (
            'setDisplayMediaRequestHandler((e,t)=>{'
            f'if("linux"===process.platform/*{BRANCH_MARK}*/)return void t({{audio:"loopback"}});'
        )
        # Apply from the end so the earlier offset stays valid.
        edits = sorted([(g.start(), g.end(), gate_repl), (b.start(), b.end(), branch_repl)], reverse=True)
        for start, end, repl in edits:
            data = data[:start] + repl + data[end:]
        path.write_text(data, encoding="utf-8", errors="surrogateescape")
        status = "APPLIED"

with open(report_path, "a", encoding="utf-8") as report:
    report.write(f"{status} linux-notetaker-fixes/{name}" + (f": {detail}" if detail else "") + "\n")
print(f"  {status:<8} {name}" + (f"  ({detail})" if detail else ""))
if status == "SKIPPED" and policy == "strict":
    print("ERROR: the Notetaker display-media fix did not match this bundle. "
          "Re-audit the anchors, or build with WISPR_FLOW_PATCH_POLICY=tolerant.", file=sys.stderr)
    sys.exit(1)
if status == "SKIPPED":
    print("WARNING: skipped under the tolerant policy: the meeting recorder will not get system audio "
          "through Chromium; use wispr-flow --notetaker-audio on instead.")
PY

if command -v node >/dev/null 2>&1; then
	node --check "$bundle"
fi
