#!/usr/bin/env bash
# linux-hub-fixes.sh: three small main-bundle fixes for Flow Hub on Linux.
#
#   warm-deeplink   The `second-instance` handler only scans the new instance's
#                   argv for a `wispr-flow:` URL on win32. Linux delivers the
#                   login callback the same way, so widen the guard; otherwise
#                   signing in while Flow is already running drops the token.
#   hub-focusable   The Hub BrowserWindow is created `focusable:!1`; on
#                   Hyprland that leaves a window nothing can type into.
#   singleton-exit  The losing instance calls app.quit(), which runs
#                   ready listeners that start services before exiting. Use
#                   app.exit() so the singleton hand-off is synchronous.
#
# Policy: strict (default) fails when any fix cannot be applied; tolerant
# reports and continues. Idempotent through inline markers.
#
# Usage: linux-hub-fixes.sh <.webpack/main/index.js> [--policy strict|tolerant] [--report FILE]

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
results = []

FIXES = [
    (
        "warm-deeplink",
        "WISPR_LINUX_WARM_DEEPLINK",
        re.compile(
            r'(?P<head>e\.app\.on\("second-instance".{0,700}?else\{)'
            r'if\([\w$]+\.[\w$]+\)'
            r'(?P<tail>\{const [\w$]+=[\w$]+\(r\.find\(e=>e\.startsWith\("wispr-flow:)',
            re.S,
        ),
        lambda m, mark: f'{m.group("head")}if(!0/*{mark}*/){m.group("tail")}',
    ),
    (
        "hub-focusable",
        "WISPR_LINUX_HUB_FOCUSABLE",
        re.compile(r'(?P<head>title:"Flow Hub".{0,700}?)focusable:!1', re.S),
        lambda m, mark: f'{m.group("head")}focusable:!0/*{mark}*/',
    ),
    (
        "singleton-exit",
        "WISPR_LINUX_SINGLETON_EXIT",
        re.compile(r'(?P<head>App is already running, quitting"\),void e\.app\.)quit\(\)'),
        lambda m, mark: f'{m.group("head")}exit(/*{mark}*/)',
    ),
]

changed = False
for name, marker, pattern, build in FIXES:
    if marker in data:
        results.append((name, "ALREADY", ""))
        continue
    matches = list(pattern.finditer(data))
    if len(matches) != 1:
        results.append((name, "SKIPPED", f"expected one anchor, found {len(matches)}"))
        continue
    m = matches[0]
    data = data[: m.start()] + build(m, marker) + data[m.end():]
    changed = True
    results.append((name, "APPLIED", ""))

if changed:
    path.write_text(data, encoding="utf-8", errors="surrogateescape")

with open(report_path, "a", encoding="utf-8") as report:
    for name, status, detail in results:
        report.write(f"{status} linux-hub-fixes/{name}" + (f": {detail}" if detail else "") + "\n")

skipped = [n for n, s, _ in results if s == "SKIPPED"]
for name, status, detail in results:
    print(f"  {status:<8} {name}" + (f"  ({detail})" if detail else ""))
if skipped and policy == "strict":
    print(f"ERROR: Hub fix(es) did not match this bundle: {', '.join(skipped)}. "
          "Re-audit the anchors, or build with WISPR_FLOW_PATCH_POLICY=tolerant.", file=sys.stderr)
    sys.exit(1)
if skipped:
    print(f"WARNING: skipped under the tolerant policy: {', '.join(skipped)}. "
          "Sign in with Wispr Flow fully stopped if the login callback is not picked up.")
PY

if command -v node >/dev/null 2>&1; then
	node --check "$bundle"
fi
