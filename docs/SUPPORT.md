# Deep State Meeting Agent — Support

Record your meetings, transcribe them on your own device, and keep every file where you put it. Here's how to get help.

## Contact us

Questions, problems, feature requests, or anything about your data — email us and a human will reply.

**YOUR_SUPPORT_EMAIL**

We aim to reply within **2 business days**. If you're reporting a bug, it helps to include your macOS or iOS version, the app version (shown in the app footer), and what you were doing when it happened.

Prefer a public tracker? You can also [open an issue on GitHub](https://github.com/jessiegibson/deep-state/issues).

## What the app does

Deep State Meeting Agent records meetings — audio on its own, or your screen and audio together on a Mac — and turns the audio into a written transcript. Transcription runs **on your device** using a local speech model. Your recordings are saved as ordinary files in a folder you choose, or in your own iCloud Drive.

There is no account to create, no server of ours to sign in to, and we never receive your recordings. See the [Privacy Policy](PRIVACY.md) for the full detail.

## System requirements

| Platform | Requirement |
| --- | --- |
| Mac | macOS 15.6 or later. Screen recording requires macOS 14 or later. |
| iPhone / iPad | iOS or iPadOS 18.0 or later. Audio recording only — screen recording is a Mac feature. |
| Storage | Space for your recordings, plus a few hundred megabytes for the on-device transcription model. |
| Network | Needed once, to download the transcription model. Recording and transcribing work offline after that. |

## Getting started

The first time you open the app it walks you through the permissions it needs and asks where to save your recordings. Each permission screen explains what the permission is for, then macOS or iOS asks you to approve it. You can decline any of them — the app will simply have less it can do.

| Permission | What it's used for | If you decline |
| --- | --- | --- |
| Microphone | Recording meeting audio | The app can't record. This one is required. |
| Screen Recording *(Mac)* | Capturing the screen you pick in Screen + Audio mode | Audio Only mode still works. |
| Speech Recognition | Showing a live transcript while you record | You still get a full transcript after recording ends. |
| Calendar | Naming recordings after the meeting on your calendar and suggesting speaker names from attendees | You name recordings yourself. |

## Common questions

### Where are my recordings saved?

Wherever you chose during setup — either a folder on your device, or the app's iCloud Drive folder. Each recording becomes its own folder named with the date and time, containing:

- `transcript.md` — the title, date, your notes, and the transcript
- `audio.m4a` — the recorded audio
- `video.mov` — the screen recording, if you used Screen + Audio mode
- `Summarization_transcript.md` — only if you generated an AI summary

These are normal files. You can open, move, back up, or delete them in Finder or the Files app without going through the app at all.

### How do I change where recordings are saved?

Open **Storage Settings** in the app and switch between iCloud and a local folder, or pick a different folder. Changing the location affects new recordings — existing ones stay where they are, so move them yourself if you want everything in one place.

### I denied a permission by mistake. How do I turn it back on?

macOS and iOS remember your choice, and the app can't ask a second time. Change it in system settings:

**On a Mac:** System Settings → Privacy & Security, then pick Microphone, Screen & System Audio Recording, Speech Recognition, or Calendars, and switch Deep State Meeting Agent on. Screen recording changes require quitting and reopening the app.

**On iPhone or iPad:** Settings → Privacy & Security, or scroll to Deep State Meeting Agent in the app list at the bottom of Settings.

### The first recording is stuck on preparing or transcribing

The first time you transcribe anything, the app downloads its speech model — a large file, and it only happens once. On a slow or intermittent connection this can time out. Connect to Wi-Fi and try again; the app will pick up where it left off.

After the model is on your device, transcription works with no network connection at all.

### My screen recording has no sound, or the wrong sound

Screen + Audio mode captures the audio playing on your Mac and your microphone as separate sources, then mixes them. If one is missing, check in the app that both are switched on before you start recording.

If you're on Bluetooth headphones, be aware that macOS switches audio modes when a microphone becomes active, which can change the recording quality mid-call. Wired headphones or your Mac's built-in microphone avoid this entirely.

### The transcript is empty or says it's unavailable

Your audio is still safe — the app saves the recording before it transcribes, so a transcription failure never costs you the recording. Open the recording in the library and run transcription again.

If it keeps failing, check that the audio file actually contains sound by playing it. Silent recordings usually mean the wrong input device was selected, or the microphone permission was revoked between recordings.

### My recordings aren't syncing between my Mac and my iPhone

Syncing only happens when both devices are set to iCloud storage in Storage Settings, signed in to the same Apple Account, with iCloud Drive turned on. Recordings saved to a local folder stay on that device by design.

Large video files can take a while to upload. Check that iCloud Drive isn't paused and that you have space in your iCloud account.

### What is the AI summary, and does it send my transcript somewhere?

It's optional and off unless you set it up. If you add your own API key for an AI provider, you can ask the app to summarize a transcript you choose. When you do, the **text of that transcript** is sent to the provider you picked — never your audio or video.

If you'd rather nothing leave your device, either don't configure a key, or choose the local Ollama option, which runs on your own machine. Full detail is in the [Privacy Policy](PRIVACY.md).

### How do I delete a recording, and does that delete your copy?

Delete the recording's folder in Finder or the Files app, or remove it from within the app. There is no copy of ours to delete — your recordings never reach us. See the [Privacy Policy](PRIVACY.md).

### Is it legal to record my meetings?

That depends on where you and the other participants are. Some places require every participant to consent before a conversation is recorded; others require only one. The app doesn't announce that recording is happening, so telling the people you're meeting with is on you.

We can't give legal advice — if you're unsure about the rules where you are, please check locally.

## Still stuck?

Email **YOUR_SUPPORT_EMAIL**

Tell us what you were trying to do, what happened instead, and which device and app version you're on. We read every message.

---

[Privacy Policy](PRIVACY.md) · [Source on GitHub](https://github.com/jessiegibson/deep-state) · [Report a bug](https://github.com/jessiegibson/deep-state/issues)

Deep State Meeting Agent is made by Solo AI. Not affiliated with Apple Inc.
