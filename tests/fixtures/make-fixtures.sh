#!/usr/bin/env bash
# make-fixtures.sh: build synthetic, non-proprietary stand-ins for every input
# of scripts/assemble-app.sh so the whole pipeline can be exercised in CI.
#
# The generated main bundle contains only the code shapes the Linux patches
# anchor on (valid JavaScript, no Wispr Flow code). Three flavours mirror the
# minifier layouts the patches were audited against:
#   old      1.6.447 layout (inline helper env, no BLE guard)
#   new      1.6.774 layout (helper env factory, BLE guard, Notetaker strings)
#   unknown  a layout with fresh identifiers: exercises the derivation paths
# --skip-optional omits the optional-fix anchors (meeting recorder frame,
# warm deep link) to exercise the tolerant policy.
#
# Usage: make-fixtures.sh OUTDIR [--flavour old|new|unknown] [--version X.Y.Z]
#                        [--electron X.Y.Z] [--windows-electron X.Y.Z] [--skip-optional]
# Needs: node, zip, an `asar` command (or npx to fetch @electron/asar).

set -Eeuo pipefail

out=''
flavour='old'
version='1.6.774'
electron='42.3.0'
windows_electron=''
skip_optional=false
while (($#)); do
	case "$1" in
		--flavour) flavour="${2:-}"; shift ;;
		--version) version="${2:-}"; shift ;;
		--electron) electron="${2:-}"; shift ;;
		--windows-electron) windows_electron="${2:-}"; shift ;;
		--skip-optional) skip_optional=true ;;
		-h|--help) sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
		*) out="$1" ;;
	esac
	shift
done
[[ -n $out ]] || { printf 'Usage: make-fixtures.sh OUTDIR [options]\n' >&2; exit 2; }
[[ $flavour == old || $flavour == new || $flavour == unknown ]] || { printf 'Unknown flavour: %s\n' "$flavour" >&2; exit 2; }
windows_electron="${windows_electron:-$electron}"

for cmd in node zip; do
	command -v "$cmd" >/dev/null 2>&1 || { printf 'Missing %s\n' "$cmd" >&2; exit 1; }
done
mkdir -p "$out/bin"
if command -v asar >/dev/null 2>&1; then
	asar_cmd="$(command -v asar)"
else
	command -v npx >/dev/null 2>&1 || { printf 'Missing asar (and npx)\n' >&2; exit 1; }
	cat > "$out/bin/asar" <<'WRAP'
#!/usr/bin/env bash
exec npx --yes @electron/asar "$@"
WRAP
	chmod +x "$out/bin/asar"
	asar_cmd="$out/bin/asar"
fi
printf '%s\n' "$asar_cmd" > "$out/asar-path"

app="$out/app"
rm -rf "$app" "$out/nupkg" "$out/electron"
mkdir -p "$app/.webpack/main/native_modules/lib" "$app/.webpack/renderer/hub" "$app/.webpack/renderer/status"
[[ $flavour == new ]] && mkdir -p "$app/.webpack/renderer/meeting_recorder" "$app/.webpack/renderer/calendar_reminder"

cat > "$app/package.json" <<JSON
{ "name": "wispr-flow", "productName": "Wispr Flow", "version": "$version", "main": ".webpack/main/index.js" }
JSON

# --- main bundle -------------------------------------------------------------
{
	cat <<'JS'
"use strict";
const f={tD:"darwin"===process.platform,H8:"win32"===process.platform,kL:"dsn",M0:"prod",yj:"seg",jd:"ph",iP:false,g:{}};
const E={ty:{isHelperProcessRunningManually:false}};
const _={ZI:process.resourcesPath};
const l=()=>({info(){},error(){}}),d=()=>require("fs"),a={app:{isPackaged:true}};
const c=f,i={app:{getAppPath:()=>"/x",on(){},quit(){},exit(){},requestSingleInstanceLock:()=>true},BrowserWindow:class{},screen:{getDisplayNearestPoint(){},getCursorScreenPoint(){}}};
const B=e=>e,L=e=>e,W=()=>{},x={RA:{}},P={RA:{}},p={ZZ:{}},O={_W:{},SB:{}},h={},m={},y=f,A=f,u=0;
JS
	if [[ $flavour == new ]]; then
		cat <<'JS'
const N=(e=a.app.isPackaged)=>({sentryDSN:f.kL,environment:f.M0,segmentWriteKey:f.yj,postHogProjectKey:f.jd,sentryLocalDebug:f.iP?"true":""});
function startHelper(){const s=f.tD?E.ty.isHelperProcessRunningManually?(l().info("Running Dev Mac Helper service"),`${_.ZI}/swift-helper-app/Wispr Flow`):(l().info("Running packaged Mac Helper service"),`${_.ZI}/swift-helper-app-dist/Wispr Flow`):E.ty.isHelperProcessRunningManually?(l().info("Running Dev Windows Helper service"),`${_.ZI}\\windows-helper-app\\Wispr Flow Helper.exe`):(l().info("Running packaged Windows Helper service"),`${_.ZI}\\Release\\Wispr Flow Helper.exe`);if(!d().existsSync(s))return void l().error("Helper service script path not found");return require("child_process").spawn(s,{stdio:["pipe","pipe","pipe","pipe"],env:N()})}
const notetakerLabel="Notetaker";
JS
	else
		cat <<'JS'
function startHelper(){const s=f.tD?E.ty.isHelperProcessRunningManually?(l().info("Running Dev Mac Helper service"),`${_.ZI}/swift-helper-app/Wispr Flow`):(l().info("Running packaged Mac Helper service"),`${_.ZI}/swift-helper-app-dist/Wispr Flow`):E.ty.isHelperProcessRunningManually?(l().info("Running Dev Windows Helper service"),`${_.ZI}\\windows-helper-app\\Wispr Flow Helper.exe`):(l().info("Running packaged Windows Helper service"),`${_.ZI}\\Release\\Wispr Flow Helper.exe`);if(!d().existsSync(s))return void l().error("Helper service script path not found");return require("child_process").spawn(s,{stdio:["pipe","pipe","pipe","pipe"],env:{sentryDSN:f.kL,environment:f.M0,segmentWriteKey:f.yj,postHogProjectKey:f.jd,sentryLocalDebug:f.iP?"true":""}})}
JS
	fi
	cat <<'JS'
const v=()=>{if(c.H8)return!1;const e=i.app.getAppPath();return!/\/Applications\//.test(e)};
if(f.H8){const e=B(process.argv.find(e=>e.startsWith("wispr-flow:")||e.startsWith("wispr-flow/")));e&&L(e)}
JS
	if ! $skip_optional; then
		cat <<'JS'
function makeRecorder(t){f.tD?Object.assign(t,{frame:!1,titleBarStyle:"hidden",trafficLightPosition:{x:1e4,y:10}}):"win32"===process.platform&&Object.assign(t,{titleBarStyle:"hidden",autoHideMenuBar:!0});return t}
JS
	fi
	cat <<'JS'
(function(e){e.app.requestSingleInstanceLock()||(l().info("App is already running, quitting"),void e.app.quit());
JS
	if $skip_optional; then
		cat <<'JS'
e.app.on("second-instance",(t,r)=>{if(f.tD){W()}else{W()}});
JS
	else
		cat <<'JS'
e.app.on("second-instance",(t,r)=>{if(f.tD){W()}else{if(f.H8){const n=B(r.find(e=>e.startsWith("wispr-flow:")));n&&L(n)}else W()}});
JS
	fi
	cat <<'JS'
const hub=new e.BrowserWindow({title:"Flow Hub",show:!1,focusable:!1,webPreferences:{}});})(i);
JS
	case "$flavour" in
		old)
			cat <<'JS'
function runtimeFixes(){
const G=()=>{const e=x.RA.statusWindow;e.showInactive(),a().info("Showing status window")};
Ye=(e=v.H8)=>{const t=ne.RA.statusWindow;if(!t||t.isDestroyed())return a().error("Status window is not available or destroyed. Recreating."),void(ne.RA.statusWindow=W());const n=t.isAlwaysOnTop(),r=t.isVisible();if(n&&r)e&&(t.setAlwaysOnTop(!0,"screen-saver"),t.showInactive());else{t.setAlwaysOnTop(!0,"screen-saver"),t.showInactive()}};
const start=e=>{(()=>{(0,ee.ui)(!0)})(e),ke(O._W.Listening),foo()};
const stop=e=>{ke(O._W.Stopping),Ve(e),foo()};
const te=e=>foo(e,A.tD,A.H8,570,u,480),ne=1;
const teInner=e=>{const{x:c,y:u,width:h,height:m}=p(e,t,r,i);return{x:c+(h-o)/2,y:u+m-s,width:o,height:s}};
const status=e=>{p.ZZ.status=e,p.ZZ.statusLastUpdatedTime=Date.now();const s=foo()};
const W=()=>{const e=i.screen.getDisplayNearestPoint(i.screen.getCursorScreenPoint()),t=te(e),n=new i.BrowserWindow({show:!1,webPreferences:{...m.g,preload:require("path").resolve(__dirname,"../renderer","status","preload.js"),backgroundThrottling:!1}},...t)};
const A1=n=>{n.setAlwaysOnTop(!0,"screen-saver"),n.setIgnoreMouseEvents(!0,{forward:!0}),A.tD&&n.setVisibleOnAllWorkspaces(!0,{vi:1})};
const ipc1=e=>{K||(e?Z(x.RA.statusWindow):V()?.setIgnoreMouseEvents(!0,{forward:!0}),(0,h.cA)(x.RA.statusWindow))};
const O=(t,n)=>{v()&&A===n&&!e.isDestroyed()&&e.setIgnoreMouseEvents(t,{forward:!0})};
const J=()=>{K||(K=!0,X(),x.RA.statusWindow&&!x.RA.statusWindow.isDestroyed()&&x.RA.statusWindow.setIgnoreMouseEvents(!0,{forward:!0}))};
}
JS
			;;
		new)
			cat <<'JS'
function runtimeFixes(){
const G=()=>{const e=x.RA.statusWindow;e.showInactive(),y.H8&&(J||ee(e),e.setAlwaysOnTop(!0,"screen-saver")),ge(ie),o().info("Showing status window")};
Ye=(e=y.H8)=>{const t=ie.RA.statusWindow;if(!t||t.isDestroyed())return o().error("Status window is not available or destroyed. Recreating."),void(ie.RA.statusWindow=W());const n=t.isAlwaysOnTop(),r=t.isVisible();if(n&&r)e&&(t.setAlwaysOnTop(!0,"screen-saver"),t.showInactive());else{t.setAlwaysOnTop(!0,"screen-saver"),t.showInactive()}};
const start=e=>{(()=>{(0,ne.ui)(!0)})(e),e===O.SB.BLE&&qe(O._W.Listening),foo()};
const stop=e=>{qe(O._W.Stopping),nt(e),foo()};
const te=e=>foo(e,y.tD,y.H8,586,u,512),Se=1;
const teInner=e=>{const{x:c,y:u,width:h,height:m}=p(e,t,r,i);return{x:c+(h-a)/2,y:u+m-s,width:a,height:s}};
const status=e=>{p.ZZ.status=e,p.ZZ.statusLastUpdatedTime=Date.now();const s=foo()};
const W=()=>{const e=i.screen.getDisplayNearestPoint(i.screen.getCursorScreenPoint()),t=te(e),n=new i.BrowserWindow({show:!1,webPreferences:{...f.g,preload:require("path").resolve(__dirname,"../renderer","status","preload.js"),backgroundThrottling:!1}},...t)};
const A1=n=>{n.setAlwaysOnTop(!0,"screen-saver"),y.H8?F.replaceWindow(n):n.setIgnoreMouseEvents(!0,{forward:!0}),y.tD&&n.setVisibleOnAllWorkspaces(!0,{vi:1})};
const ipc1=e=>{K||(e?Z(P.RA.statusWindow):Y()?.setIgnoreMouseEvents(!0,{forward:!0}),(0,m.cA)(P.RA.statusWindow))};
const M=(t,n)=>{v()&&f===n&&!e.isDestroyed()&&(t?e.setIgnoreMouseEvents(!0,{forward:!0}):e.setIgnoreMouseEvents(!1))};
const J=()=>{K||(K=!0,X(),y.H8?Y()?.setIgnoreMouseEvents(!0,{forward:!0}):P.RA.statusWindow&&!P.RA.statusWindow.isDestroyed()&&P.RA.statusWindow.setIgnoreMouseEvents(!0,{forward:!0}))};
}
JS
			;;
		unknown)
			cat <<'JS'
function runtimeFixes(){
const G=()=>{const e=Rz.RA.statusWindow;e.showInactive(),q9.H8&&(Jk||ee(e),e.setAlwaysOnTop(!0,"screen-saver")),ge(zz),o2().info("Showing status window")};
Ye=(e=q9.H8)=>{const t=zz.RA.statusWindow;if(!t||t.isDestroyed())return o2().error("Status window is not available or destroyed. Recreating."),void(zz.RA.statusWindow=W());const n=t.isAlwaysOnTop(),r=t.isVisible();if(n&&r)e&&(t.setAlwaysOnTop(!0,"screen-saver"),t.showInactive());else{t.setAlwaysOnTop(!0,"screen-saver"),t.showInactive()}};
const showHub=()=>{(0,Q.Bn)(zz.RA.hubWindow,T.Y6.ShowHub)};
const start=e=>{(()=>{(0,ab.ui)(!0)})(e),setSt(P2._W.Listening),foo()};
const stop=e=>{setSt(P2._W.Stopping),nt2(e),foo()};
const te=e=>foo(e,q9.tD,q9.H8,600,u,520),Se2=1;
const teInner=e=>{const{x:c,y:u,width:h,height:m}=p(e,t,r,i);return{x:c+(h-w)/2,y:u+m-s,width:w,height:s}};
const status=e=>{p2.ZZ.status=e,p2.ZZ.statusLastUpdatedTime=Date.now();const s=foo()};
const W=()=>{const e=i.screen.getDisplayNearestPoint(i.screen.getCursorScreenPoint()),t=te(e),n=new i.BrowserWindow({show:!1,webPreferences:{...g7.g,preload:require("path").resolve(__dirname,"../renderer","status","preload.js"),backgroundThrottling:!1}},...t)};
const A1=n=>{n.setAlwaysOnTop(!0,"screen-saver"),q9.H8?F2.replaceWindow(n):n.setIgnoreMouseEvents(!0,{forward:!0}),q9.tD&&n.setVisibleOnAllWorkspaces(!0,{vi:1})};
const ipc1=e=>{K||(e?Z(Rz.RA.statusWindow):Yq()?.setIgnoreMouseEvents(!0,{forward:!0}),(0,m2.cA)(Rz.RA.statusWindow))};
const Mq=(t,n)=>{v()&&g7===n&&!e.isDestroyed()&&(t?e.setIgnoreMouseEvents(!0,{forward:!0}):e.setIgnoreMouseEvents(!1))};
const J=()=>{K||(K=!0,X(),q9.H8?Yq()?.setIgnoreMouseEvents(!0,{forward:!0}):Rz.RA.statusWindow&&!Rz.RA.statusWindow.isDestroyed()&&Rz.RA.statusWindow.setIgnoreMouseEvents(!0,{forward:!0}))};
}
JS
			;;
	esac
} > "$app/.webpack/main/index.js"
node --check "$app/.webpack/main/index.js"

# --- renderers ----------------------------------------------------------------
cat > "$app/.webpack/renderer/hub/index.js" <<'JS'
"use strict";document.documentElement.classList.add(window.electron.platform.os);const y=window.electron,$=y?.platform?.isMacOS??!1,x=y?.platform?.isWindows??!1;const label=x?"Ctrl":"Cmd";
JS
cat > "$app/.webpack/renderer/status/index.js" <<'JS'
"use strict";const y=window.electron,x=y?.platform?.isWindows??!1;const delay=x?200:100;
JS
if [[ $flavour == new ]]; then
	cat > "$app/.webpack/renderer/meeting_recorder/index.js" <<'JS'
"use strict";const recorder={start(){},stop(){}};
JS
	cat > "$app/.webpack/renderer/calendar_reminder/index.js" <<'JS'
"use strict";const reminder={show(){}};
JS
fi
for renderer in "$app"/.webpack/renderer/*/index.js; do node --check "$renderer"; done
# A Windows-only native module that must be dropped from the Linux asar.
printf 'MZ' > "$app/.webpack/main/native_modules/lib/crypt32-win32-x64.node"

# --- nupkg ---------------------------------------------------------------------
mkdir -p "$out/nupkg/lib/net45/resources/assets/logos" "$out/nupkg/lib/net45/resources/migrations"
"$asar_cmd" pack "$app" "$out/nupkg/lib/net45/resources/app.asar" --unpack '*.node' >/dev/null
printf '<svg xmlns="http://www.w3.org/2000/svg"/>\n' > "$out/nupkg/lib/net45/resources/assets/logos/flow-symbol.svg"
printf -- '-- fixture migration\n' > "$out/nupkg/lib/net45/resources/migrations/0001-init.sql"
printf '%s\n' "$windows_electron" > "$out/nupkg/lib/net45/version"
nupkg="$out/WisprFlow-${version}-full.nupkg"
rm -f "$nupkg"
(cd "$out/nupkg" && zip -qr "$nupkg" .)

# --- Electron zip ---------------------------------------------------------------
mkdir -p "$out/electron/resources"
cp /bin/true "$out/electron/electron"
cp /bin/true "$out/electron/chrome-sandbox"
: > "$out/electron/icudtl.dat"
: > "$out/electron/resources.pak"
printf 'v%s\n' "$electron" > "$out/electron/version"
printf 'MIT (fixture)\n' > "$out/electron/LICENSE"
printf '<html>fixture</html>\n' > "$out/electron/LICENSES.chromium.html"
electron_zip="$out/electron-v${electron}-linux-x64.zip"
rm -f "$electron_zip"
(cd "$out/electron" && zip -qr "$electron_zip" .)

# --- native module and helper stand-ins (real x86_64 ELF binaries) -------------
cp /bin/true "$out/node_sqlite3-x86_64.node"
cp /bin/true "$out/wispr-flow-linux-helper-x86_64"

printf 'Fixtures ready in %s (flavour=%s version=%s electron=%s windows-electron=%s skip-optional=%s)\n' \
	"$out" "$flavour" "$version" "$electron" "$windows_electron" "$skip_optional"
