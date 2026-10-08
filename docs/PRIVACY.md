# Privacy Policy

**Last updated: 24 August 2026**

This policy explains what Deep State Meeting Agent ("the app") does with your information. It applies to the app on macOS, iOS, and iPadOS, published by Solo AI ("we", "us").

**The short version.** The app has no user accounts and no server of ours. Your audio recordings, screen recordings, and transcripts are written as files to a location you choose — a folder on your device, or your own iCloud Drive. We do not collect them, cannot access them, and never see them. There is no analytics, no advertising, and no tracking of any kind.

## Information we collect

**We collect nothing.** The app does not create an account for you, does not ask for your name or email, and does not transmit your content or usage to us. We operate no backend service that receives data from the app.

Everything described below is data the app creates and stores *on your own device or in your own iCloud account*, under your control.

## Screen recordings

When you choose **Screen + Audio** mode on a Mac, Deep State Meeting Agent records the display you select and the audio playing on your Mac, and saves it as a video file. This recording is stored only in the location you choose — a folder on your Mac, or your own iCloud Drive. It is never transmitted to us or to any third party, and we have no ability to access it. We do not analyze the contents of your screen recordings for any purpose: no text recognition, no image analysis, no extraction of anything shown on screen. Recording starts only when you start it and stops when you stop it; the app cannot record your screen in the background or without your knowledge, and macOS displays its own recording indicator whenever capture is active. You may delete your screen recordings at any time by deleting the files. We retain no copy, because we never receive one.

Screen recording is a Mac-only feature. The iPhone and iPad versions of the app do not record the screen at all.

## Audio recordings and transcripts

The app records audio through your microphone, and in Screen + Audio mode also captures the audio playing on your Mac. That audio is saved as a file alongside the recording.

To produce a transcript, the audio is processed by a speech recognition model that runs **on your device**. The audio is not uploaded for transcription. The app also uses Apple's built-in speech recognition to show a live transcript while you record; that is handled by the operating system under Apple's own privacy terms, and we receive nothing from it.

Transcripts are saved as plain Markdown text files next to the recording.

## Calendar information

If you grant calendar access, the app reads events from your calendar so it can suggest a title for a recording and offer attendee names as speaker labels. This is read on your device, used immediately, and never transmitted anywhere. If you decline calendar access, the rest of the app works normally and you title recordings yourself.

## Where your files are stored

You choose the storage location when you first set up the app, and can change it at any time in Storage Settings:

- **A folder on your device** that you select. The app can write only to the folder you picked.
- **Your iCloud Drive**, in the app's own container within your personal Apple Account. This is what lets recordings appear on your other devices. Files stored there are governed by [Apple's privacy policy](https://www.apple.com/legal/privacy/); we have no access to your iCloud account.

Recordings are saved as ordinary files. You can open, move, back up, or delete them with Finder or the Files app without involving the app.

## Retention and deletion

Your recordings stay until *you* delete them. The app never deletes them on its own and never expires them. To delete a recording, remove its folder — that is the complete and final deletion, because no other copy exists. We hold no backup and cannot recover a deleted recording for you.

## Network connections the app makes

The app connects to the internet in only two situations:

1. **Downloading the transcription model.** The first time you transcribe something, the app downloads the speech recognition model it runs locally. This is a download only — none of your content is sent.
2. **The optional AI summary feature**, described below, and only if you have set it up and asked for a summary.

Apart from these, the app does not communicate over the network. It does not phone home, check in, or report usage.

## Optional AI summaries

The app can generate a written summary of a transcript using an external AI provider. **This feature is off unless you turn it on**, and turning it on requires you to supply your own API key for a provider you have your own relationship with.

When you explicitly ask for a summary of a specific transcript:

- The **text of that transcript** is sent to the provider you selected — currently one of Anthropic, OpenAI, Google Gemini, Moonshot (KIMI), or a local Ollama instance.
- **Your audio and video are never sent** — only the text.
- Nothing is sent unless you press the button for that specific transcript.
- The provider's handling of that text is governed by their privacy policy and your agreement with them, not ours. We are not a party to it and receive nothing.

If you choose the **Ollama (Local)** option, the model runs on your own machine and the transcript does not leave your device. If you never configure an API key, this feature stays inactive and no transcript is ever sent anywhere.

Your API keys are stored in your device's Keychain. We never see them.

## Sharing with third parties

We do not sell, rent, share, or disclose your information — because we do not have it. There are no advertisers, data brokers, analytics vendors, or partners of any kind receiving anything from this app.

The only circumstance in which any of your content reaches a third party is the optional AI summary feature described above, which you must deliberately configure and invoke, and which sends transcript text only.

## Analytics and tracking

None. The app contains no analytics SDK, no crash reporting service of ours, no advertising identifier, and no tracking across apps or websites. We do not build a profile of you.

If you choose to send Apple crash and usage data through your device's own settings, that goes to Apple under Apple's terms; it is anonymized and contains none of your recordings.

## Children

The app is not directed at children under 13, and we do not knowingly collect information from anyone — including children — because we do not collect information at all.

## Your rights

Privacy laws such as the GDPR and CCPA give you rights to access, correct, export, or delete personal data a company holds about you. We hold none, so there is nothing for us to produce or erase. Your recordings are already in your possession, in open file formats, and you can copy or delete them at will.

If you would like this confirmed in writing for your records, email us and we'll respond.

## Recording other people

Laws about recording conversations differ by country, state, and province — some require the consent of everyone involved. The app does not notify other participants that you are recording. Complying with the law where you are, including telling people when required, is your responsibility.

## Changes to this policy

If we change this policy we'll update the date at the top of this page and, for anything material, note the change in the app's release notes. Because the app collects nothing, changes are most likely to be clarifications rather than expansions of what we do.

## Contact

Questions about this policy or about your data:

**YOUR_SUPPORT_EMAIL**

---

Deep State Meeting Agent is made by Solo AI. Not affiliated with Apple Inc.
