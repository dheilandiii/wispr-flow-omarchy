#!/usr/bin/env bash
# linux-notetaker-fixes.sh: fixes for Notetaker on Linux.
#
#   display-media   (main bundle) The meeting recorder captures the other side
#                   of a call with getDisplayMedia({audio:true}), which Electron
#                   only serves when the main process installed a display-media
#                   request handler. The client installs one on macOS and
#                   Windows and logs "Skipping handler install on Linux (no
#                   system loopback path)" on Linux, so the recorder's
#                   system-audio request is rejected before Chromium is even
#                   asked. Chromium's PulseAudio backend serves the request on
#                   Linux by recording the monitor of the default output (no
#                   feature flag involved; the monitor must not be turned down,
#                   see wispr-flow --system-audio). This fix keeps the skip
#                   unless WISPR_FLOW_NOTETAKER_LOOPBACK=1 is set (the launcher
#                   exports it) and answers Linux requests with
#                   {audio:"loopback"}, the same answer Windows gets. Two
#                   coordinated sites, applied together or not at all.
#
#   windows-gate    (hub renderer, --hub) Flow Hub hides Notetaker behind a
#                   Windows rollout: it shows "Notetaker is coming soon" when
#                   its isWindows local is true and the PostHog feature flag
#                   notetaker-windows is off. The port widens that local to be
#                   true on Linux (port/linux-renderer-treat-as-windows), and
#                   PostHog evaluates the flag for a Linux device, so Linux got
#                   the rollout wall although the same client shows Notetaker on
#                   Windows. The fix ANDs the isWindows read inside that one
#                   hook with `"linux"!==window.electron?.platform?.os`, so the
#                   gate never applies on Linux; the flag itself is untouched.
#
# A bundle without a display-media handler (Wispr Flow < Notetaker) reports
# ABSENT, and so does a hub renderer that never reads the notetaker-windows
# flag; both satisfy both policies. Policy: strict (default) fails when a
# present anchor cannot be patched; tolerant reports and continues. Idempotent
# through inline markers.
#
# Usage: linux-notetaker-fixes.sh <.webpack/main/index.js> [--hub <.webpack/renderer/hub/index.js>]
#                                 [--policy strict|tolerant] [--report FILE]

set -Eeuo pipefail

bundle=''
hub=''
policy="${WISPR_FLOW_PATCH_POLICY:-strict}"
report=''
while (($#)); do
	case "$1" in
		--policy) policy="${2:-}"; shift ;;
		--report) report="${2:-}"; shift ;;
		--hub) hub="${2:-}"; shift ;;
		*) bundle="$1" ;;
	esac
	shift
done
usage() {
	printf 'Usage: %s <.webpack/main/index.js> [--hub <.webpack/renderer/hub/index.js>] [--policy strict|tolerant] [--report FILE]\n' "$0" >&2
	exit 2
}
[[ -f $bundle ]] || usage
[[ -z $hub || -f $hub ]] || { printf 'ERROR: --hub is not a file: %s\n' "$hub" >&2; exit 2; }
[[ $policy == strict || $policy == tolerant ]] || { printf 'ERROR: policy must be strict or tolerant.\n' >&2; exit 2; }

python3 - "$bundle" "$policy" "${report:-/dev/null}" "$hub" <<'PY'
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
policy = sys.argv[2]
report_path = sys.argv[3]
hub_arg = sys.argv[4]
failed = []

def record(name, status, detail=""):
    with open(report_path, "a", encoding="utf-8") as report:
        report.write(f"{status} linux-notetaker-fixes/{name}" + (f": {detail}" if detail else "") + "\n")
    print(f"  {status:<8} {name}" + (f"  ({detail})" if detail else ""))
    if status == "SKIPPED":
        failed.append(name)

# --- display-media (main bundle) ---------------------------------------------
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
record("display-media", status, detail)

# --- windows-gate (hub renderer) ---------------------------------------------
if hub_arg:
    hub_path = pathlib.Path(hub_arg)
    hub = hub_path.read_text(encoding="utf-8", errors="surrogateescape")
    WIN_MARK = "WISPR_LINUX_NOTETAKER_WINDOWS_GATE"
    LINUX = '"linux"!==window.electron?.platform?.os'
    # The hook that decides the Windows rollout wall. Every identifier is
    # derived: the flag hook, the enum object, the resolved-flags getter, the
    # platform module and its isWindows export. `TO.NotetakerWindows` is the
    # preserved developer enum member (= "notetaker-windows").
    WIN_GATE = re.compile(
        r'\{const\{isEnabled:(?P<en>[\w$]+)\}=\(0,(?P<hook>[\w$]+)\.(?P<hookfn>[\w$]+)\)'
        r'\((?P<enum>[\w$]+)\.TO\.NotetakerWindows\),(?P<res>[\w$]+)=(?P<resolved>[\w$]+)\(\);'
        r'return\{blocked:\((?P<a>[\w$]+)=(?P<plat>[\w$]+)\.(?P<win>[\w$]+),(?P<i>[\w$]+)=(?P=en),(?P=a)&&!(?P=i)\),'
        r'isLoading:(?P=plat)\.(?P=win)&&!(?P=res)\}'
    )
    status, detail = "", ""
    if WIN_MARK in hub:
        status = "ALREADY"
    elif ".TO.NotetakerWindows" not in hub:
        status, detail = "ABSENT", "hub renderer never reads the notetaker-windows flag (no Windows rollout gate)"
    else:
        matches = list(WIN_GATE.finditer(hub))
        if len(matches) != 1:
            status, detail = "SKIPPED", f"expected one Windows rollout gate, found {len(matches)}"
        else:
            m = matches[0]
            plat, win = m.group("plat"), m.group("win")
            repl = (
                f'{{const{{isEnabled:{m.group("en")}}}=(0,{m.group("hook")}.{m.group("hookfn")})'
                f'({m.group("enum")}.TO.NotetakerWindows),{m.group("res")}={m.group("resolved")}();'
                f'return{{blocked:({m.group("a")}={plat}.{win}&&{LINUX}/*{WIN_MARK}*/,{m.group("i")}={m.group("en")},'
                f'{m.group("a")}&&!{m.group("i")}),isLoading:{plat}.{win}&&{LINUX}&&!{m.group("res")}}}'
            )
            hub = hub[:m.start()] + repl + hub[m.end():]
            hub_path.write_text(hub, encoding="utf-8", errors="surrogateescape")
            status = "APPLIED"
    record("windows-gate", status, detail)

if failed and policy == "strict":
    print("ERROR: the Notetaker fix(es) " + ", ".join(failed) + " did not match this bundle. "
          "Re-audit the anchors, or build with WISPR_FLOW_PATCH_POLICY=tolerant.", file=sys.stderr)
    sys.exit(1)
if failed:
    print("WARNING: skipped under the tolerant policy: " + ", ".join(failed) + ". "
          "display-media: the meeting recorder will not get system audio through Chromium "
          "(use wispr-flow --notetaker-audio on); windows-gate: Flow Hub keeps the "
          "\"Notetaker is coming soon\" wall.")
PY

if command -v node >/dev/null 2>&1; then
	node --check "$bundle"
	[[ -z $hub ]] || node --check "$hub"
fi
