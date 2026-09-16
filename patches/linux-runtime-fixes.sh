#!/usr/bin/env bash
# linux-runtime-fixes.sh: Hyprland-specific runtime fixes for the Wispr Flow
# main bundle (.webpack/main/index.js).
#
# What it changes (all gated at runtime by WISPR_FLOW_* environment variables
# that bin/wispr-flow sets, so an unpatched site simply means the variable has
# no effect):
#   show-guard        keep the Flow Status Indicator hidden when asked
#   dictation-guard   do not recreate/show the indicator on dictation start
#   transient-show    map the indicator only while dictating
#   transient-hide    unmap it again on Idle/Error/Dismissed
#   start-sound       play the start sound in the Hub renderer (helper has none)
#   stop-sound        same for the stop sound
#   status-bounds     configurable indicator size (compact/zoomed)
#   zoom-prefs        matching renderer zoom factor
#   geometry          configurable vertical position of the indicator (marker STATUS_POSITION)
#   interactive       optional click-through disable (experimental)
#   interactive-ipc   same, for the renderer-driven mouse toggle
#   hit-test          same, for the alpha hit-test poller
#   tour              same, for the feature tour
#
# Every sub-patch is anchored on developer strings and syntactic shapes and
# derives the minified identifiers from the match, so it survives Wispr's
# re-minification as long as the code shape holds (audited against 1.6.447,
# 1.6.774 and 1.6.872; the last one re-minified the dock-edge geometry of the
# indicator, which is why status-bounds and geometry derive every identifier).
# When a shape moves, the outcome depends on the policy:
#   strict   (default) any sub-patch that cannot be applied aborts the build
#   tolerant  skipped sub-patches are reported and the build continues
#
# Usage: linux-runtime-fixes.sh <.webpack/main/index.js> [--policy strict|tolerant]
#                               [--report FILE]
# Environment: WISPR_FLOW_PATCH_POLICY provides the default policy.
# Exit 0 when the policy is satisfied, 1 otherwise. Re-running is a no-op.

set -Eeuo pipefail

bundle=''
policy="${WISPR_FLOW_PATCH_POLICY:-strict}"
report=''
while (($#)); do
	case "$1" in
		--policy) policy="${2:-}"; shift ;;
		--report) report="${2:-}"; shift ;;
		-h|--help)
			sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'
			exit 0
			;;
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
source = path.read_text(encoding="utf-8", errors="surrogateescape")
patched = source
results = []  # (name, status, detail)

ENV_HIDE = 'process.env.WISPR_FLOW_HIDE_STATUS_WINDOW'
ENV_TRANSIENT = 'process.env.WISPR_FLOW_TRANSIENT_STATUS_WINDOW'
ENV_COMPACT = 'process.env.WISPR_FLOW_COMPACT_STATUS_WINDOW'
ENV_CLICKABLE = 'process.env.WISPR_FLOW_STATUS_CLICKABLE'
ENV_ZOOM = 'process.env.WISPR_FLOW_STATUS_ZOOM'
ZOOM_EXPR = f'{ENV_ZOOM}?parseFloat({ENV_ZOOM}):1.45'

MARK = {
    "show-guard": "WISPR_LINUX_HIDE_STATUS_WINDOW_SHOW",
    "dictation-guard": "WISPR_LINUX_HIDE_STATUS_WINDOW_DICTATION",
    "transient-show": "WISPR_LINUX_TRANSIENT_STATUS_SHOW",
    "start-sound": "WISPR_LINUX_LOCAL_START_SOUND",
    "stop-sound": "WISPR_LINUX_LOCAL_STOP_SOUND",
    "status-bounds": "WISPR_LINUX_COMPACT_STATUS_WINDOW",
    "transient-hide": "WISPR_LINUX_TRANSIENT_STATUS_HIDE",
    "zoom-prefs": "WISPR_LINUX_STATUS_ZOOM",
    "geometry": "WISPR_LINUX_STATUS_POSITION",
    "interactive": "WISPR_LINUX_STATUS_INTERACTIVE",
    "interactive-ipc": "WISPR_LINUX_STATUS_IPC",
    "hit-test": "WISPR_LINUX_STATUS_HITTEST",
    "tour": "WISPR_LINUX_STATUS_TOUR",
}


class Skip(Exception):
    pass


def unique(pattern, label, text=None, flags=0):
    """Return the single match of PATTERN or raise Skip with a count."""
    text = patched if text is None else text
    matches = list(re.finditer(pattern, text, flags))
    if len(matches) != 1:
        raise Skip(f"expected one {label} anchor, found {len(matches)}")
    return matches[0]


def already(name):
    return MARK[name] in patched


def record(name, status, detail=""):
    results.append((name, status, detail))


def apply(name, fn):
    """Run FN, which mutates `patched` or raises Skip."""
    global patched
    if already(name):
        record(name, "ALREADY")
        return
    before = patched
    try:
        fn()
    except Skip as skip:
        patched = before
        record(name, "SKIPPED", str(skip))
        return
    except Exception as error:  # a shape we did not foresee must never abort the build silently
        patched = before
        record(name, "SKIPPED", f"{type(error).__name__}: {error}")
        return
    if patched == before:
        record(name, "SKIPPED", "substitution produced no change")
        return
    record(name, "APPLIED")


# ---------------------------------------------------------------------------
# Context derived once from the bundle. Each derivation raises Skip when the
# bundle does not expose the shape; the sub-patches that need it then skip.
# ---------------------------------------------------------------------------
def derive_dictation():
    """The dictation-start status-window recovery site.

    Yields the `<alias>.RA.statusWindow` accessor used in the dictation
    controller's scope; the other sub-patches reuse the alias for the same
    module (`ne.RA` in 1.6.447, `ie.RA` in 1.6.774)."""
    match = unique(
        r'(?P<head>[\w$]+=\(e=[^)]+\)=>\{)'
        r'(?P<declaration>const (?P<window>[\w$]+)='
        r'(?P<status>(?P<ra>[\w$]+)\.RA\.statusWindow);'
        r'if\(!(?P=window)\|\|(?P=window)\.isDestroyed\(\)\)return '
        r'[\w$]+\(\)\.error\("Status window is not available or destroyed\. Recreating\."\))',
        "dictation status-window recovery",
    )
    return match


def derive_start():
    """Dictation start: `<set>(<statusEnum>._W.Listening),` right after the
    `(0,<x>.ui)(!0)})(e),` call. 1.6.774 inserted an `e===<..>.BLE&&` guard."""
    return unique(
        r'\(0,[\w$]+\.ui\)\(!0\)\}\)\(e\),'
        r'(?P<ble>(?:e===[\w$]+\.[\w$]+\.BLE&&)?)'
        r'(?P<set>[\w$]+)\((?P<enum>[\w$]+)\._W\.Listening\),',
        "dictation-start",
    )


def derive_sound_channel(ra_alias):
    """Find `(0,<send>)(<ra>.RA.hubWindow,<enum>.<Member>)`: the send-to-Hub
    helper plus the renderer IPC enum used to play the dictation sounds.

    Known bundles: 1.6.447 -> (V.Bn, E.Y6), 1.6.774 and 1.6.872 -> (K.Bn, _.Y6).
    Those literals are tried first; otherwise the pair is derived from any
    existing send-to-Hub call in the same module scope."""
    known = {
        ("ne", "(0,ee.ui)(!0)})(e),ke(O._W.Listening),"): ("V.Bn", "E.Y6"),
        ("ie", "(0,ne.ui)(!0)})(e),e===O.SB.BLE&&qe(O._W.Listening),"): ("K.Bn", "_.Y6"),
    }
    for (alias, anchor), pair in known.items():
        if alias == ra_alias and anchor in patched:
            return pair
    pairs = set(
        re.findall(
            r'\(0,(?P<send>[\w$]+\.[\w$]+)\)\(' + re.escape(ra_alias)
            + r'\.RA\.hubWindow,(?P<enum>[\w$]+\.[\w$]+)\.[A-Z][\w$]*\)',
            patched,
        )
    )
    if len(pairs) != 1:
        raise Skip(f"could not derive the Hub sound channel (candidates: {sorted(pairs)})")
    return pairs.pop()


context = {}
try:
    m = derive_dictation()
    context["dictation"] = m
    context["ra"] = m.group("ra")
except Skip as skip:
    context["dictation_error"] = str(skip)

try:
    m = derive_start()
    context["start"] = m
    context["enum"] = m.group("enum")
except Skip as skip:
    context["start_error"] = str(skip)


def need(key):
    if key not in context:
        raise Skip(context.get(f"{key}_error", f"missing {key} context"))
    return context[key]


def ra():
    return need("ra") + ".RA"


def status_enum():
    if "enum" in context:
        return context["enum"]
    aliases = set(re.findall(r'([\w$]+)\._W\.Dismissed', patched))
    if len(aliases) != 1:
        raise Skip(f"could not derive the status enum alias (candidates: {sorted(aliases)})")
    return aliases.pop()


# ---------------------------------------------------------------------------
# Sub-patches.
# ---------------------------------------------------------------------------
def show_guard():
    global patched
    m = unique(
        r'(?P<window>[\w$]+)\.showInactive\(\),'
        r'(?P<mid>(?:[^;{}]{0,240}?,)?)'
        r'(?P<logger>[\w$]+)\(\)\.info\("Showing status window"\)',
        "Flow Status Indicator show site",
    )
    w, mid, lg = m.group("window"), m.group("mid"), m.group("logger")
    repl = (
        f'(/*{MARK["show-guard"]}*/"1"==={ENV_HIDE}?'
        f'({w}.hide(),{lg}().info("Linux: Flow Status Indicator kept hidden")):'
        f'({w}.showInactive(),{mid}{lg}().info("Showing status window")))'
    )
    patched = patched[: m.start()] + repl + patched[m.end():]


def dictation_guard():
    global patched
    orig = need("dictation")
    # Re-locate the same text on the current bundle: earlier sub-patches may
    # have shifted it. The named groups come from the original match.
    loc = unique(re.escape(orig.group(0)), "dictation status-window recovery")
    window, status = orig.group("window"), orig.group("status")
    guard = (
        f'if(/*{MARK["dictation-guard"]}*/"1"==={ENV_HIDE}&&"1"!=={ENV_TRANSIENT})'
        f'{{const {window}={status};{window}&&!{window}.isDestroyed()&&{window}.hide();return}}'
    )
    patched = (
        patched[: loc.start()] + orig.group("head") + guard + orig.group("declaration") + patched[loc.end():]
    )


def transient_show():
    global patched
    m = need("start")
    m = unique(re.escape(m.group(0)), "dictation-start")
    insert = f'/*{MARK["transient-show"]}*/"1"==={ENV_TRANSIENT}&&{ra()}.statusWindow?.showInactive(),'
    patched = patched[: m.end()] + insert + patched[m.end():]


def start_sound():
    global patched
    m = need("start")
    send, enum = derive_sound_channel(need("ra"))
    m = unique(re.escape(m.group(0)), "dictation-start")
    insert = (
        f'/*{MARK["start-sound"]}*/{ra()}.prefs?.user.enableSounds&&'
        f'(0,{send})({ra()}.hubWindow,{enum}.PlayDictationStartSound),'
    )
    patched = patched[: m.end()] + insert + patched[m.end():]


def stop_sound():
    global patched
    send, enum = derive_sound_channel(need("ra"))
    m = unique(
        r'(?P<set>[\w$]+)\((?P<enum>[\w$]+)\._W\.Stopping\),(?P<stop>[\w$]+)\(e\),',
        "dictation-stop",
    )
    insert = (
        f'/*{MARK["stop-sound"]}*/{ra()}.prefs?.user.enableSounds&&'
        f'(0,{send})({ra()}.hubWindow,{enum}.PlayDictationStopSound),'
    )
    head = patched[m.start(): m.start("stop")]
    patched = patched[: m.start()] + head + insert + patched[m.start("stop"):]


def transient_hide():
    global patched
    enum = status_enum()
    m = unique(
        r'(?P<zz>[\w$]+)\.ZZ\.status=e,(?P=zz)\.ZZ\.statusLastUpdatedTime=Date\.now\(\);const (?P<s>[\w$]+)=',
        "status-update",
    )
    zz, s = m.group("zz"), m.group("s")
    repl = (
        f'{zz}.ZZ.status=e,{zz}.ZZ.statusLastUpdatedTime=Date.now(),'
        f'/*{MARK["transient-hide"]}*/"1"==={ENV_TRANSIENT}&&'
        f'[{enum}._W.Idle,{enum}._W.Error,{enum}._W.Dismissed].includes(e)&&{ra()}.statusWindow?.hide();const {s}='
    )
    patched = patched[: m.start()] + repl + patched[m.end():]


def status_bounds():
    """`<flags>.tD,<flags>.H8,<height>,<side>,<width>),<next>=`: the trailing
    arguments of the indicator geometry call. <side> is the size object of the
    left/right dock edges (`u` in 1.6.774, `d` in 1.6.872) and is kept as is."""
    global patched
    m = unique(
        r'(?P<flags>[\w$]+)\.tD,(?P=flags)\.H8,(?P<height>\d{3}),(?P<side>[\w$]+),(?P<width>\d{3})\),(?P<next>[\w$]+)=',
        "status-window bounds",
    )
    flags, height, side, width, nxt = (
        m.group("flags"), m.group("height"), m.group("side"), m.group("width"), m.group("next")
    )
    height_expr = (
        f'"1"==={ENV_COMPACT}?96:'
        f'/*WISPR_LINUX_STATUS_GEOMETRY*/(process.env.WISPR_FLOW_STATUS_H?+process.env.WISPR_FLOW_STATUS_H:'
        f'Math.round({height}*({ZOOM_EXPR})))'
    )
    width_expr = (
        f'/*{MARK["status-bounds"]}*/"1"==={ENV_COMPACT}?180:'
        f'(process.env.WISPR_FLOW_STATUS_W?+process.env.WISPR_FLOW_STATUS_W:'
        f'Math.round({width}*({ZOOM_EXPR})))'
    )
    repl = f'{flags}.tD,{flags}.H8,{height_expr},{side},{width_expr}),{nxt}='
    patched = patched[: m.start()] + repl + patched[m.end():]


def zoom_prefs():
    global patched
    m = unique(
        r'webPreferences:\{\.\.\.[\w$]+\.g,preload:require\("path"\)\.resolve\(__dirname,'
        r'"\.\./renderer","status","preload\.js"\),backgroundThrottling:!1\}',
        "status webPreferences",
    )
    anchor = m.group(0)
    repl = (
        anchor[:-1]
        + f',/*{MARK["zoom-prefs"]}*/zoomFactor:{ENV_ZOOM}?parseFloat({ENV_ZOOM})'
        f':("1"==={ENV_COMPACT}?1:1.45)}}'
    )
    patched = patched[: m.start()] + repl + patched[m.end():]


def geometry():
    """The bottom-edge return of the indicator geometry:
    `return{x:<x>+(<dw>-<w>)/2,y:<y>+<dh>-<h>,width:<w>,height:<h>}` where
    <x>,<y>,<dw>,<dh> are the display work area and <w>,<h> the indicator size.
    1.6.872 added left/right dock edges in the same function; their return
    (`x:<i>,y:<y>+(<dh>-<h>)/2`) does not match this shape and is left alone."""
    global patched
    m = unique(
        r'return\{x:(?P<x>[\w$]+)\+\((?P<dw>[\w$]+)-(?P<w>[\w$]+)\)/2,'
        r'y:(?P<y>[\w$]+)\+(?P<dh>[\w$]+)-(?P<h>[\w$]+),width:(?P=w),height:(?P=h)\}',
        "status geometry return",
    )
    x, dw, w, y, dh, h = (m.group(k) for k in ("x", "dw", "w", "y", "dh", "h"))
    repl = (
        f'return{{x:{x}+({dw}-{w})/2,y:{y}+{dh}-{h},width:{w},height:{h},'
        f'...(/*{MARK["geometry"]}*/"1"==={ENV_TRANSIENT}&&"1"!=={ENV_COMPACT}'
        f'?{{y:Math.round({y}+{dh}*parseFloat(process.env.WISPR_FLOW_STATUS_Y||"0.83")-{h}/2)}}:{{}})}}'
    )
    patched = patched[: m.start()] + repl + patched[m.end():]


def interactive():
    global patched
    m = unique(
        r'(?P<w>[\w$]+)\.setAlwaysOnTop\(!0,"screen-saver"\),'
        r'(?P<pre>(?:[\w$]+\.H8\?[\w$]+\.replaceWindow\((?P=w)\):)?)'
        r'(?P=w)\.setIgnoreMouseEvents\(!0,\{forward:!0\}\),'
        r'(?P<flags>[\w$]+)\.tD&&(?P=w)\.setVisibleOnAllWorkspaces',
        "status ignore-mouse",
    )
    w, pre, flags = m.group("w"), m.group("pre"), m.group("flags")
    guard = f'/*{MARK["interactive"]}*/"1"!=={ENV_CLICKABLE}&&{w}.setIgnoreMouseEvents(!0,{{forward:!0}})'
    if pre:
        guard = f'{pre}({guard})'
    repl = f'{w}.setAlwaysOnTop(!0,"screen-saver"),{guard},{flags}.tD&&{w}.setVisibleOnAllWorkspaces'
    patched = patched[: m.start()] + repl + patched[m.end():]


def interactive_ipc():
    global patched
    m = unique(
        r':(?P<fn>[\w$]+)\(\)\?\.setIgnoreMouseEvents\(!0,\{forward:!0\}\),'
        r'\(0,(?P<ca>[\w$]+\.cA)\)\((?P<sw>[\w$]+\.RA\.statusWindow)\)',
        "status EnableMouseEvents",
    )
    fn, ca, sw = m.group("fn"), m.group("ca"), m.group("sw")
    repl = (
        f':(/*{MARK["interactive-ipc"]}*/"1"!=={ENV_CLICKABLE}&&{fn}()?.setIgnoreMouseEvents(!0,{{forward:!0}}),'
        f'(0,{ca})({sw}))'
    )
    patched = patched[: m.start()] + repl + patched[m.end():]


def hit_test():
    global patched
    m = unique(
        r'(?P<name>[\w$]+)=\(t,n\)=>\{(?P<vis>[\w$]+)\(\)&&(?P<id>[\w$]+)===n&&!e\.isDestroyed\(\)&&'
        r'(?P<body>e\.setIgnoreMouseEvents\(t,\{forward:!0\}\)'
        r'|\(t\?e\.setIgnoreMouseEvents\(!0,\{forward:!0\}\):e\.setIgnoreMouseEvents\(!1\)\))\}',
        "alpha hit-test poller",
    )
    head = patched[m.start(): m.start("body")]
    repl = f'{head}/*{MARK["hit-test"]}*/(!t||"1"!=={ENV_CLICKABLE})&&{m.group("body")}}}'
    patched = patched[: m.start()] + repl + patched[m.end():]


def tour():
    global patched
    m = unique(
        r'(?P<pre>(?:(?P<flags>[\w$]+)\.H8\?(?P<fn>[\w$]+)\(\)\?\.setIgnoreMouseEvents\(!0,\{forward:!0\}\):)?)'
        r'(?P<sw>[\w$]+\.RA\.statusWindow)&&!(?P=sw)\.isDestroyed\(\)&&(?P=sw)\.setIgnoreMouseEvents\(!0,\{forward:!0\}\)',
        "feature-tour suspend",
    )
    sw = m.group("sw")
    pre = ""
    if m.group("pre"):
        pre = (
            f'{m.group("flags")}.H8?("1"!=={ENV_CLICKABLE}&&'
            f'{m.group("fn")}()?.setIgnoreMouseEvents(!0,{{forward:!0}})):'
        )
    repl = (
        f'{pre}{sw}&&!{sw}.isDestroyed()&&/*{MARK["tour"]}*/"1"!=={ENV_CLICKABLE}&&'
        f'{sw}.setIgnoreMouseEvents(!0,{{forward:!0}})'
    )
    patched = patched[: m.start()] + repl + patched[m.end():]


# Order matters only for anchors that overlap: dictation-guard, transient-show
# and start-sound re-locate their anchors on the current text.
apply("show-guard", show_guard)
apply("dictation-guard", dictation_guard)
apply("transient-show", transient_show)
apply("start-sound", start_sound)
apply("transient-hide", transient_hide)
apply("stop-sound", stop_sound)
apply("status-bounds", status_bounds)
apply("zoom-prefs", zoom_prefs)
apply("interactive", interactive)
apply("interactive-ipc", interactive_ipc)
apply("geometry", geometry)
apply("hit-test", hit_test)
apply("tour", tour)

skipped = [(n, d) for n, s, d in results if s == "SKIPPED"]
applied = [n for n, s, _ in results if s == "APPLIED"]

if applied:
    path.write_text(patched, encoding="utf-8", errors="surrogateescape")

with open(report_path, "a", encoding="utf-8") as report:
    for name, status, detail in results:
        line = f"{status} linux-runtime-fixes/{name}"
        if detail:
            line += f": {detail}"
        report.write(line + "\n")

for name, status, detail in results:
    print(f"  {status:<8} {name}" + (f"  ({detail})" if detail else ""))

if skipped and policy == "strict":
    print(
        f"ERROR: {len(skipped)} Hyprland runtime fix(es) did not match this bundle. "
        "Re-audit the anchors, or build with WISPR_FLOW_PATCH_POLICY=tolerant to "
        "ship without them.",
        file=sys.stderr,
    )
    sys.exit(1)
if skipped:
    print(f"WARNING: {len(skipped)} optional runtime fix(es) skipped under the tolerant policy.")
print(f"linux-runtime-fixes: {len(applied)} applied, "
      f"{sum(1 for _, s, _ in results if s == 'ALREADY')} already present, {len(skipped)} skipped")
PY

if command -v node >/dev/null 2>&1; then
	node --check "$bundle"
fi
