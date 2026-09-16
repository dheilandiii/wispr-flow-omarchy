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
linux-notetaker-fixes/windows-gate` afterwards. Confirmed on Omarchy
4.0.0.alpha with 1.6.872: after the rebuild the Notetaker page shows
recordings, upcoming meetings and settings.

## System audio: two paths, one monitor

Both paths read the **monitor of the default output**, the PipeWire source
named `<sink>.monitor`: Chromium's PulseAudio backend records the monitor of
`@DEFAULT_SINK@` for a loopback request, and the Notetaker mix loops
`@DEFAULT_MONITOR@` into its sink. The monitor carries a volume of its own
that no playback control shows (pipewire-pulse maps it to the sink node's
`monitorVolumes`), and WirePlumber does not restore it. Wispr Flow itself
turns it down: 186 ms after the recorder logs `Loopback audio track
acquired`, the monitor drops from 100% to 8%, which is 20 of the 255 input
levels Chromium's audio input path uses (observed on Omarchy 4.0.0.alpha,
Dell XPS 9320, PipeWire 1.6.8, with a 0.5 s poll of the sink's
`monitorVolumes`). The recorder then keeps a live track (`readyState:
'live'`) but logs `[MeetingSystemWorklet] sustained all-zero PCM detected`
every ten seconds: `parecord` of the monitor measured -91 dB at 8% while a
tone played through the speakers, and -26 dB at 100% with the same tone.

So the launcher starts a guard with Flow: `wispr-flow-configure system-audio
guard <electron pid>` follows PulseAudio events and sets the monitor back to
100% whenever it drops, for as long as that Electron process lives (one per
session, `flock`-guarded; `WISPR_FLOW_MONITOR_GUARD=0` turns it off). Its
lines land in `wispr-flow --logs` as `system-audio guard: restored to 100%:
...`. The one-shot commands remain:

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

## The microphone hears the speakers: echo cancellation

With system audio flowing, the first transcript on Omarchy carried every
sentence of a YouTube video twice: as "Them" from the loopback and as "You"
from the laptop microphone, which hears the speakers. The recorder asks
Chromium for `echoCancellation` with `requestedAecMode: 'all'`; on macOS and
Windows that is the operating system's cancellation of everything the machine
plays, on Linux Chromium can only cancel audio it plays itself. Wispr's own
echo detector (`Echo detector init { mode: 'suppress' }`) does engage, but on
that recording only after a 28.8 s warm-up (`Echo conf-room summary`:
`correlatedWindows: 62, suppressedWindows: 53, warmupBaselineOnsetSeconds:
28.8`) and it mutes the mic rather than cancelling the bleed.

PipeWire has the missing piece, its echo-cancel module with the WebRTC engine
(`pipewire-audio`), and the port wires it up:

```bash
wispr-flow --notetaker-mic on      # creates "Wispr Notetaker Mic (echo cancelled)" and makes it the default input
wispr-flow --notetaker-mic status  # modules, reference delay, default input
wispr-flow --notetaker-mic off     # removes it and restores the real microphone as default
```

Three `pactl` modules: a null sink that swallows what the canceller would
play back, the echo-cancel module (real microphone in, `wispr_notetaker_mic`
out), and a loopback that feeds the default output's monitor into the
canceller as the reference. Wispr Flow follows the default input for
dictation and Notetaker, so nothing needs selecting in the app; the launcher
recreates the modules after an audio restart as long as the feature is on.

Measured on the XPS 9320 (Omarchy 4.0.0.alpha, PipeWire 1.6.8), the raw
microphone versus the cancelled source while the speakers played a
speech-like signal at the machine's 40% volume:

| | raw microphone | cancelled |
| --- | --- | --- |
| room quiet | -72.8 dB mean | -90.3 dB mean |
| speakers playing | -56.4 dB mean, -40.5 dB peak | -87.3 dB mean, -66.2 dB peak |

Synthetically (a null sink standing in for the microphone) the engine passed
near-end speech through at -1.4 dB and cancelled a 40 ms-late echo by 47 dB;
at 120 ms it managed 14 dB. That is the catch: the echo reaches this laptop's
microphone about 206 ms after the monitor carries the signal (8 x 1024-frame
ALSA periods, 170 ms of output buffering, plus capture), and the canceller
needs its reference shortly before the echo. The loopback's `latency_msec`
sets how much reference queues ahead of the microphone: 170 cancelled 26 to
31 dB in every run, including with a 10 ms-latency client active, while 140
and 200 cancelled almost nothing. The default is therefore the default
output's ALSA buffer length (`api.alsa.period-size x api.alsa.period-num`),
170 ms here and the fallback when PipeWire does not report it;
`WISPR_FLOW_AEC_DELAY_MS` overrides it. If a transcript still doubles
lines, try 30 ms up or down and compare, with audio playing:

```bash
timeout 6 parecord --device=wispr_notetaker_mic /tmp/aec.wav && ffmpeg -i /tmp/aec.wav -af volumedetect -f null -
```

`pw-loopback` with `target.delay.sec` is not a substitute: it added 372 to
415 ms in tests and the canceller produced full-scale noise from it. A
256-frame `node.latency` for the module crashes it (division by zero in the
WebRTC wrapper); the module runs at the graph's quantum. A filter-chain with
an exact `delay` node feeding the canceller's sink did not cancel in any of
seven runs (100 to 190 ms); not understood, not pursued.

### Alignment is set at start, so `on` verifies it

The lead is not a function of `latency_msec` alone. The canceller consumes
its microphone and reference buffers in lockstep, so whatever offset the two
streams have when they start persists for the life of the instance, and
that offset depends on timing at start. Fresh starts of the same 170 ms
setting cancelled 28 dB or 2 dB; a sweep in one regime read 100 fail, 130
ok, 170 ok, 200 fail, 230 ok, 260 ok. The recordings on this machine showed
the same: the instance built at 23:57 gave 1 correlated echo window in 17,
the one rebuilt at 00:10 gave 34 in 77.

`wispr-flow --notetaker-mic on` therefore plays a 4 s speech-like test
signal through the speakers, records the real microphone and the cancelled
source at the same time, and accepts the instance only when the cancelled
source is at least 12 dB quieter; otherwise it restarts the reference
loopback and tries again, up to four times. `status` shows the result under
`Self-test:` with both levels. The test needs the speakers audible to the
microphone; if it reports "not verified", turn the volume up and run `on`
again. `WISPR_FLOW_AEC_VERIFY=0` skips it. The launcher's recreation after
an audio restart runs without the test (no sounds at login) and marks the
instance "not verified"; run `on` to verify it.

### The gate after the canceller

Cancellation alone was not enough for the transcriber. A recording made
through the cancelled source still carried garbled "You" copies of the
video, and the recorder's echo detector counted 34 correlated windows and
suppressed none: the residual (about -60 dB peak) is too faint for Wispr's
detector and loud enough for a speech model that normalises level, with
Chromium's gain control amplifying it on the way. So `--notetaker-mic on`
adds a fourth module when the LADSPA gate from `swh-plugins` is installed:
`module-ladspa-source` with `gate_1410` after the canceller, exposing
`wispr_notetaker_mic_gated`, which becomes the default input instead.
The threshold compares against the signal's average level, not its peaks:
with synthetic input, -55 dB blocked material averaging -70 dB (peaks -58)
and passed material averaging -55 dB (peaks -44) and louder. The residual
averages -85 dB here, a voice at the built-in microphone -45 to -25 dB, so
the default is -55 dB (`WISPR_FLOW_MIC_GATE_DB`), attack 5 ms, hold 250 ms,
decay 300 ms, range -90 dB. Below the threshold the source is real silence,
so nothing is left to transcribe; a quiet talker far from the laptop may
need -60.
`WISPR_FLOW_MIC_GATE=0` skips the stage; without `swh-plugins`, `status`
says so and the ungated canceller is used.

```bash
sudo pacman -S --needed swh-plugins ladspa   # gate plugin (2 MB) and analyseplugin
```

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
  volume, the mix sink, the echo-cancelled microphone, and whether the
  installed bundle carries the Notetaker UI and the display-media patch.
- Every line of a transcript appears twice, once as "Them" and once as
  "You": the microphone hears the speakers; `wispr-flow --notetaker-mic on`.
- No system audio in the transcript, or `sustained all-zero PCM detected` in
  `wispr-flow --logs`: `wispr-flow --system-audio check`, then
  `wispr-flow --system-audio fix`. The launcher logs the monitor volume on
  every start and its guard logs every restore; no `system-audio guard:
  started` line after the start line means the guard did not run (check
  `WISPR_FLOW_MONITOR_GUARD`, `setsid`, `flock`). If the monitor is fine,
  enable the mix, select it as the microphone, and check
  `pactl list short modules | grep wispr_notetaker_mix`.
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
