# App Review Response — Submission 9e44fb4b-a619-4ceb-9437-537b42eb24c6

Rejection date: 2026-08-19 · Version reviewed: 0.8 (20260626)

Five issues were raised. Three are fixed in code (2.4.5(i), 5.1.1(iv), 5.2.5); two need
action outside the repo (1.5 Support URL, 2.1 screen-recording questionnaire).

Apple's note applies to all of it: **do not upload a new binary just to answer questions.**
2.4.5(i) and 2.1 are answered by replying in App Store Connect. The binary changes below
ride along with the next build, which requires a Developer Reject first.

---

## 1. Guideline 2.4.5(i) — unused entitlements — FIXED IN CODE

Apple flagged three entitlements with no matching functionality:

| Entitlement | Verdict | Where it came from |
| --- | --- | --- |
| `com.apple.security.network.server` | Not used — removed | `ENABLE_INCOMING_NETWORK_CONNECTIONS = YES` |
| `com.apple.security.files.downloads.read-write` | Not used — removed | `ENABLE_FILE_ACCESS_DOWNLOADS_FOLDER = readwrite` |
| `com.apple.security.device.camera` | Not used — removed | `ENABLE_RESOURCE_ACCESS_CAMERA = YES` + entitlements file |

None of the three had a call site. The only `AVCaptureDevice` usage in the app is
`.audio` (microphone); there is no video capture path at all.

The important part: two of the three were **not in `MeetingAgent.entitlements`**. They were
injected at build time by Xcode's `ENABLE_*` build settings in `project.pbxproj`, which is
why an earlier cleanup of the entitlements file did not remove them from the shipped binary.

Verified on the built product:

Remaining entitlements, all with a live call site:

- `com.apple.security.app-sandbox` — required for Mac App Store distribution
- `com.apple.security.device.audio-input` — microphone recording (`AudioRecorder`)
- `com.apple.security.files.user-selected.read-write` — user-chosen save folder
- `com.apple.security.network.client` — WhisperKit model download; optional LLM summary
- `com.apple.security.personal-information.calendars` — `CalendarManager`, meeting titles
- iCloud container / ubiquity / CloudDocuments — iCloud Drive sync of recordings

### Suggested reply in App Store Connect

> Thank you for the review. All three entitlements were unused and have been removed from
> the binary:
>
> - `com.apple.security.network.server` — the app never listens for incoming connections.
> - `com.apple.security.files.downloads.read-write` — the app writes only to a folder the
>   user explicitly chooses, or to its iCloud container.
> - `com.apple.security.device.camera` — the app has no camera or video-capture feature.
>   All capture is microphone audio and, optionally, ScreenCaptureKit screen recording.
>
> All three were injected by Xcode build settings rather than declared in our entitlements
> file, which is why they persisted after an earlier cleanup. The next build will contain
> only: app-sandbox, audio-input, user-selected file access, network client (for
> on-device transcription model download), calendars, and our iCloud container.

---

## 2. Guideline 5.1.1(iv) — permission pre-prompts — FIXED IN CODE

Two specific complaints, both in `MeetingAgent/Views/OnboardingView.swift`:

1. The button read **"GRANT PERMISSION"**. → now reads **"CONTINUE"**.
2. A **BACK** button let the user leave the explanation screen without the system prompt
   ever firing. → BACK is removed from onboarding entirely; `CONTINUE` on a permission
   step always calls the system request before advancing.

The explanation copy was also rewritten to state plainly what the data is used for and that
macOS will ask next, rather than reading as a pitch for granting access.

Applies to all four permission steps (microphone, screen recording, speech recognition,
calendar), not just the two Apple named.

---

## 3. Guideline 5.2.5 — "macOS" in the app name — FIXED IN CODE + ASC ACTION NEEDED

Root cause found: the macOS target's **Release** configuration had drifted to
`PRODUCT_BUNDLE_IDENTIFIER = com.soloai.meetingAgentMacOS` while Debug kept
`com.soloai.deepState`. Archive builds are always Release, so uploads landed on the
duplicate App Store Connect record named "Deep State Meeting Agent MacOS" — the name Apple
is objecting to. On top of that, `PRODUCT_NAME = $(TARGET_NAME)` made `CFBundleName`
literally "Deep State Meeting Agent MacOS".

Fixed in the project file:

- Release `PRODUCT_BUNDLE_IDENTIFIER` → `com.soloai.deepState` (matches Debug)
- `PRODUCT_NAME` → `"Deep State Meeting Agent"` on both configs
- Product reference and scheme `BuildableName` updated to match

Verified: `CFBundleName` and `CFBundleDisplayName` are both "Deep State Meeting Agent",
`CFBundleIdentifier` is `com.soloai.deepState`.

**This is the second time this drift has happened** (first: commit `89e787c`, 2026-07-21).

### Still needs doing in App Store Connect

- Rename the app record so the name contains no "macOS" / "Mac OS" / "MacOS".
- Confirm the next upload attaches to the `com.soloai.deepState` record, not the duplicate.
- Delete or abandon the orphaned duplicate record.

---

## 4. Guideline 1.5 — Support URL — NEEDS A REAL PAGE

`https://github.com/jessiegibson/deep-state` is not a support page. Apple wants a page a
user can land on and get help from.

Cheapest fix that satisfies review: a GitHub Pages site, or even a public repo page whose
README is a genuine support document. It must include:

- What the app does, in a sentence
- A contact method that reaches a human — a support email address is enough
- Basic help: how to grant permissions, where recordings are saved, how to change the
  save location, how to report a bug
- A link to the privacy policy

Then update the Support URL field in App Store Connect. No binary change needed.

---

## 5. Guideline 2.1 — screen-recording questionnaire — NEEDS A REPLY

Apple asked six questions. Draft answers below, based on what the code actually does —
**check each one against the shipping build before sending.**

> **Please describe all app features which use screen recording.**
>
> Screen recording is used by exactly one feature: the app's "Screen + Audio" recording
> mode. When the user starts a recording in that mode, the app uses ScreenCaptureKit to
> capture the display the user selects, together with system audio, into a single
> QuickTime movie. It is one of two recording modes; the other, "Audio Only", does not
> use screen recording at all. Recording only ever begins from an explicit user action and
> stops when the user stops it. There is no background, hidden, or automatic capture.
>
> **What data does the app collect via screen recording?**
>
> A video file of the display the user chose, plus the accompanying system audio, for the
> duration of the recording. Nothing else is derived from the video — no OCR, no analysis,
> no screenshots, no metadata extraction. The audio track is used to produce a text
> transcript.
>
> **For what purposes are you collecting this information?**
>
> Solely to give the user a record of their own meeting. The video is saved as a file the
> user can play back, and the audio is transcribed to text so the user has a searchable
> written record. The app is a personal meeting-notes tool; the recording exists for the
> user's own later reference. We do not use it for any other purpose — no analytics, no
> advertising, no model training, no profiling.
>
> **Will the data be shared with any third parties?**
>
> No. Screen recordings never leave the user's device or their own iCloud account. The app
> has no backend server and we receive no user content. Transcription runs on-device via
> WhisperKit; the video itself is never uploaded anywhere. [If the optional LLM summary
> feature ships enabled, add: the optional AI summary feature sends only the text
> transcript — never audio or video — to an AI provider the user configures with their own
> API key, and it is off unless the user turns it on.]
>
> **Where will this information be stored?**
>
> Only where the user chooses: either a local folder they pick with the system file picker,
> or the app's own iCloud Drive container in the user's personal iCloud account. Files are
> written as ordinary files (`video.mov`, `audio.m4a`, `transcript.md`) in a
> timestamped folder. The user can move or delete them at any time using Finder. We have no
> access to either location.
>
> **Which are the relevant sections of your privacy policy?** / **Please quote the specific
> language.**
>
> [Fill in once the privacy policy is published — see below.]

### Privacy policy needs screen-recording language

There is no privacy policy in the repo, and the last two questions cannot be answered
without one. It needs a section that explicitly names screen recording. Suggested text:

> **Screen recordings.** When you choose "Screen + Audio" mode, Deep State records the
> display you select and the audio playing on your Mac, and saves it as a video file. This
> recording is stored only in the location you choose — a folder on your Mac, or your own
> iCloud Drive. It is never transmitted to us or to any third party, and we have no ability
> to access it. We do not analyze the contents of your screen recordings for any purpose.
> Recording starts only when you start it and stops when you stop it. You may delete your
> recordings at any time by deleting the files. We retain no copy, because we never receive
> one.

Publish it at a stable URL, put that URL in the App Store Connect Privacy Policy field,
then quote the paragraph above in the 2.1 reply.

---

## Order of operations

1. Reply in App Store Connect to 2.4.5(i) and 2.1 — no binary needed.
2. Publish the support page and privacy policy; update both URLs in App Store Connect.
3. Rename the app record to drop "MacOS".
4. Developer Reject the current submission.
5. Bump `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`, archive, and confirm the upload
   attaches to `com.soloai.deepState`.
6. Before archiving, reset TCC so onboarding can be retested from a clean state:
   `tccutil reset All com.soloai.deepState`
