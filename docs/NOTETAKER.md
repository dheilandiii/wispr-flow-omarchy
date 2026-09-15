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
| Other participants (system audio) | WASAPI loopback | Two paths, see below |
| Calendar (Google / Microsoft 365) | OAuth in the browser, `wispr-flow:` callback | Same; the login callback is registered by `wispr-flow --setup` |
| Meeting detection (Zoom, Meet, Teams) | Windows helper reports the active app and browser URL | The Linux helper reports the active app through AT-SPI; browser URLs are not available on Wayland, so automatic "you are in a meeting" prompts may not fire. Start the recording from Flow Hub. |
| Speaker attribution | Windows audio session per app | Not available; the transcript separates speakers by voice only |

## System audio: two independent paths

1. **Chromium loopback (default).** The launcher starts Electron with
   `--enable-features=PulseaudioLoopbackForScreenShare`. When the recorder asks
   for system audio through `getDisplayMedia`, Chromium reads the monitor of
   the default PipeWire output. Nothing to configure; disable with
   `WISPR_FLOW_NOTETAKER_LOOPBACK=0` if it misbehaves.

2. **Wispr Notetaker Mix (recommended for reliability).** A PipeWire virtual
   source that mixes the default microphone with the monitor of the default
   output:

   ```bash
   wispr-flow --notetaker-audio on
   ```

   Then, in Flow Hub, pick **"Wispr Notetaker Mix (microphone + system
   audio)"** as the microphone before recording a meeting. Switch back to the
   real microphone for dictation. The launcher recreates the mix after an audio
   restart as long as it is enabled; `wispr-flow --notetaker-audio off` removes
   it. The mix follows the default input and output, so switching to a headset
   or a Bluetooth speaker in Omarchy's audio panel keeps working.

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

- `wispr-flow --doctor` shows the PipeWire state, the mix sink and whether the
  installed bundle carries the Notetaker UI.
- No system audio in the transcript: enable the mix, select it as the
  microphone, and check `pactl list short modules | grep wispr_notetaker_mix`.
- The mix disappeared: `omarchy-restart-audio` unloads all pactl modules;
  starting `wispr-flow` again recreates it, or run
  `wispr-flow --notetaker-audio on`.
- Calendar sign-in does not return to Flow: `xdg-mime query default
  x-scheme-handler/wispr-flow` must print `wispr-flow.desktop`; run
  `wispr-flow --setup` if it does not.
