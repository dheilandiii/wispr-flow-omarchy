# Notetaker on Omarchy

Wispr Flow's Notetaker records a meeting, transcribes it and writes notes into
Flow Hub. It shipped for macOS in August 2026 and for Windows on 2026-09-15.
This port assembles the Linux runtime from the Windows client, so Notetaker is
available on Omarchy once `versions.env` pins a Windows release that carries it
(see `docs/UPGRADING.md`; `wispr-flow --doctor` prints `notetaker-ui=yes` for
such a build).

## What the Windows build expects and what Linux provides

| Notetaker needs | On Windows | On Omarchy (this port) |
| --- | --- | --- |
| Microphone | WASAPI capture | PipeWire via Chromium `getUserMedia`; works out of the box |
| Other participants (system audio) | WASAPI loopback | Chromium loopback or the Notetaker mix, both from the default output's monitor (see below) |
| Calendar (Google / Microsoft 365) | OAuth in the browser, `wispr-flow:` callback | Same; the login callback is registered by `wispr-flow --setup` |
| Meeting detection (Zoom, Meet, Teams) | Windows helper reports the active app and browser URL, scans browser tab strips and native call windows (`GetMeetingTabScan`, `GetNativeCallSnapshot`, `GetConferenceEndState`) | The Linux helper reports the active app through AT-SPI and answers the meeting-scan requests with a no-op ACK; browser URLs are not available on Wayland, so automatic "you are in a meeting" prompts and automatic stop at meeting end may not fire. Start and stop recordings from Flow Hub. |
| Speaker attribution | Windows audio session per app | Not available; the transcript separates speakers by voice only |

## Flow Hub's Windows rollout wall

Flow Hub decides between the Notetaker page and "Notetaker is coming soon!
Our new meeting notetaker tool will become available on Windows soon." with
`isWindows && !flag("notetaker-windows")`, a PostHog rollout flag for the
Windows launch. The port makes the hub's `isWindows` true on Linux so the
Windows UI paths run, and PostHog evaluates the flag for a Linux device:
`~/.config/Wispr Flow/feature-flags-cache.json` held `"notetaker-windows":
{"enabled": false}` on Omarchy while the same account sees Notetaker on
Windows. `patches/linux-notetaker-fixes.sh --hub` (report line
`linux-notetaker-fixes/windows-gate`, marker
`WISPR_LINUX_NOTETAKER_WINDOWS_GATE`) makes that one check false on Linux; the
flag, the main process and the server-side entitlement are untouched. A build
made before 1.1.2 still shows the wall until `./install.sh` runs again;
`patch-report.txt` next to the runtime lists `APPLIED
linux-notetaker-fixes/windows-gate` afterwards.

## System audio: two paths, one monitor

Both paths read the **monitor of the default output**, the PipeWire source
named `<sink>.monitor`: Chromium's PulseAudio backend records the monitor of
`@DEFAULT_SINK@` for a loopback request, and the Notetaker mix loops
`@DEFAULT_MONITOR@` into its sink. The monitor carries a volume of its own
that no playback control shows (pipewire-pulse maps it to the sink node's
`monitorVolumes`); a mixer that lists monitors as recording devices can turn
it down, and WirePlumber does not restore it. The recorder then still gets a
live track (`Loopback audio track acquired`, `readyState: 'live'`) but logs
`[MeetingSystemWorklet] sustained all-zero PCM detected` every ten seconds.
That is how the first recording on Omarchy 4.0.0.alpha failed (Dell XPS 9320,
PipeWire 1.6.8): the monitor stood at 8%, `parecord` of it measured -91 dB
while a tone played through the speakers, and at 100% the same tone measured
-26 dB.

```bash
wispr-flow --system-audio check   # also part of wispr-flow --doctor
wispr-flow --system-audio fix     # monitor to 100% and unmuted; playback volume untouched
```

1. **Chromium loopback.** The recorder asks for system audio through
   `getDisplayMedia({audio:true})`. Electron only serves that request when the
   main process installed a display-media request handler, and the official
   client installs one on macOS and Windows but logs
   `[MeetingDisplayMedia] Skipping handler install on Linux (no system loopback
   path)` on Linux, so the request was rejected before Chromium was even asked.
   `patches/linux-notetaker-fixes.sh` (optional tier, marker
   `WISPR_LINUX_NOTETAKER_LOOPBACK_*`) installs the handler when
   `WISPR_FLOW_NOTETAKER_LOOPBACK=1` reaches the client (the launcher exports
   it) and answers Linux with the same `{audio:"loopback"}` Windows gets.
   Chromium then records the default sink's monitor through its
   `PulseLoopbackManager` and follows default-sink changes; no feature flag is
   involved. `PulseaudioLoopbackForScreenShare` only gates Chrome's own picker
   UI, and the client's Sentry setup calls
   `app.commandLine.appendSwitch("enable-features", ...)`, which replaces any
   `--enable-features` switch the launcher passes, so the launcher passes none.
   `wispr-flow --doctor` reports whether the installed build carries the patch;
   `WISPR_FLOW_NOTETAKER_LOOPBACK=0` turns it off. On Omarchy 4.0.0.alpha with
   1.6.872 the handler installs, the recorder logs `Loopback audio track
   acquired`, and the monitor delivers audio once it is at 100%. A transcript
   that contains the other side's speech is the remaining check.

2. **Wispr Notetaker Mix.** A PipeWire virtual source that mixes the default
   microphone with the monitor of the default output:

   ```bash
   wispr-flow --notetaker-audio on
   ```

   Then, in Flow Hub, pick **"Wispr Notetaker Mix (microphone + system
   audio)"** as the microphone before recording a meeting. Switch back to the
   real microphone for dictation. The launcher recreates the mix after an audio
   restart as long as it is enabled; `wispr-flow --notetaker-audio off` removes
   it. The mix follows the default input and output, so switching to a headset
   or a Bluetooth speaker in Omarchy's audio panel keeps working. It reads the
   same monitor as the loopback, so `--notetaker-audio on` and `status` report
   the monitor volume too.

   Do not select the mix sink as an *output*: it is a null sink and produces
   no sound. `--notetaker-audio on` refuses to run if it is the default output
   because that would loop the audio back into itself.

## Window behaviour

The managed Hyprland rules float every Wispr Flow window, center Flow Hub, keep
the dictation pill unfocusable, and pin Notetaker popups (titles containing
"reminder", "recorder", "meeting" or "notetaker") so they stay visible across
workspaces while a meeting runs.

## Consent

Recording a meeting requires the consent of everyone in it under the laws of
most jurisdictions. Notetaker does not announce itself to other participants
on Linux any more than it does on Windows.

## Troubleshooting

- `wispr-flow --doctor` shows the PipeWire state, the default output's monitor
  volume, the mix sink, and whether the installed bundle carries the Notetaker
  UI and the display-media patch.
- No system audio in the transcript, or `sustained all-zero PCM detected` in
  `wispr-flow --logs`: `wispr-flow --system-audio check`, then
  `wispr-flow --system-audio fix`. The launcher logs the monitor volume on
  every start. If the monitor is fine, enable the mix, select it as the
  microphone, and check `pactl list short modules | grep wispr_notetaker_mix`.
- Measure what the recorder hears, with audio playing:
  `timeout 6 parecord --device="$(pactl get-default-sink).monitor" /tmp/mon.wav`
  then `ffmpeg -i /tmp/mon.wav -af volumedetect -f null -`; a `mean_volume`
  near -91 dB is silence.
- The mix disappeared: `omarchy-restart-audio` unloads all pactl modules;
  starting `wispr-flow` again recreates it, or run
  `wispr-flow --notetaker-audio on`.
- Calendar sign-in does not return to Flow: `xdg-mime query default
  x-scheme-handler/wispr-flow` must print `wispr-flow.desktop`; run
  `wispr-flow --setup` if it does not.
