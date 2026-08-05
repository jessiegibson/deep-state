# Regression Register

Every bug in this project that was diagnosed and fixed once, so it does not get
re-introduced. Read this before touching entitlements, the audio pipeline, the
ScreenCaptureKit path, or `project.pbxproj`.

Format per entry: **symptom → root cause → fix → guard**. The *guard* is how you
detect the regression before shipping.

Last audited: 2026-08-04, against `main` @ `1493f9d` + uncommitted working tree.

---

## Part 1 — Landmines (do not undo these)

### L1. `com.apple.audioanalyticsd` mach-lookup exception — REMOVED. Do not add it back.

**Decision (owner, 2026-08-04, final): the app does not use this entitlement. It stays out.
Do not re-add it under any circumstance.**

The key is `com.apple.security.exception.mach-lookup.global-name` → `com.apple.audioanalyticsd`.
"Mach entitlement", "mach-lookup exception", and "the audioanalyticsd issue" all refer to this
one key.

It was added in `3d709d5` (2026-05-04) for an SCStream sandbox denial, and removed in
`cf3f580` (2026-08-04). Keeping it causes App Store Connect archive validation to fail with
error **90285** ("Invalid Code Signing Entitlements … not supported on macOS"), which blocks
`app-store-connect` export outright. That is a shipping blocker; the entitlement is not worth it.

**This entry has been re-added to the codebase twice by mistake.** Both times the trigger was
a document — this file, or an agent memory — asserting the key was "required" on the strength
of a `PRECONDITION FAILURE` log line. Do not reintroduce it on that basis. If a precondition
failure appears, the supported fix is to change the *sandbox* side, not to add the exception:
`ENABLE_APP_SANDBOX = NO` in `project.pbxproj` removes the precondition entirely, since it
fires only on the conjunction "sandboxed AND entitlement absent."

**Guard:** if you find `com.apple.audioanalyticsd` anywhere in the project, remove it.

```bash
grep -rn "audioanalytics" --include="*.entitlements" --include="*.plist" --include="*.pbxproj" .
```

No output is the correct state. Note that `build/MeetingAgent.xcarchive` (dated 2026-06-10)
still contains the key because it predates the removal — it is a stale artifact, `build/` is
gitignored, and it should not be read as evidence about current source.

---

### L2. Xcode's plist editor silently destroys entitlements — HIGH RECURRENCE RISK

Commit `e57064e` ("Updated the screens on iOS settings page") touched neither
entitlements file intentionally, yet:

- alphabetically re-serialized `MeetingAgent.entitlements`
- **deleted the XML comment** added in `6419c0d` that documented L1
- **deleted all three iCloud keys** from the macOS target
- **emptied the iOS entitlements file to `<dict/>`**, deleting all three iCloud keys there

This is the single most dangerous pattern in this repo's history: entitlement loss as
uncommented collateral damage inside an unrelated UI commit.

**Guards:**
1. Never document an entitlement with an XML comment — Xcode's serializer drops them.
   Document them *here* instead.
2. Any commit whose diff touches a `.entitlements` file must say so in its message.
3. Before every commit: `git diff -- '*.entitlements'` and read it.

---

### L3. iCloud entitlements missing from BOTH targets — FIXED 2026-08-04

Deleted in `e57064e` (2026-07-12) as collateral of L2. Missing for 23 days; **restored**
after it surfaced as a user-visible bug — the onboarding "SAVE TO iCLOUD" button did
nothing, because `url(forUbiquityContainerIdentifier:)` returns `nil` without the
entitlement, leaving `rootURL` nil. `deep-state/deep-state.entitlements` had been reduced
to a literal `<dict/>`.

All three keys are gone from both targets:
`com.apple.developer.icloud-container-identifiers`,
`com.apple.developer.icloud-services` (`CloudDocuments`),
`com.apple.developer.ubiquity-container-identifiers` — all `iCloud.soloai.MeetingAgent`.

They are **not** compensated for in `project.pbxproj` (no iCloud keys there at all).

**Impact:** cross-device iCloud sync — a core documented feature backed by
`StorageManager.shared` — cannot work on either platform. `StorageManager`'s calls into
the ubiquity container will fail at runtime; this does not break the build, so CI and a
clean compile will not catch it.

**Restored from:** `git show 6b66d6b -- deep-state/deep-state.entitlements`. Verified present
in the signed binary via `codesign -d --entitlements -`, not just in the plist.

**Guard:** iCloud sync has no automated test. Verify manually — record on one device,
confirm the folder appears on the other — before any release that claims sync works.

---

### L4. Debug/Release bundle-ID drift

`89e787c` (2026-07-21) changed **Release-only** `PRODUCT_BUNDLE_IDENTIFIER` from
`com.soloai.deepState` to `com.soloai.meetingAgent-macOS` while Debug kept the original.
Almost certainly an accidental Xcode UI edit.

**Symptom:** TestFlight (always Release) created a *brand-new* App Store Connect app record
instead of attaching to the existing one with its TestFlight history.

**Fixed same day** — both configs are back to `com.soloai.deepState` (canonical).
Still outstanding: the orphaned App Store Connect record needs manual deletion in the web UI.

**Guard:**
```bash
grep -n PRODUCT_BUNDLE_IDENTIFIER "Deep State Meeting Agent MacOS.xcodeproj/project.pbxproj"
```
All configs for a target must agree. If an upload ever creates an unexpected new app
record, check this **first**.

---

### L5. `SCRecordingOutput` does not finalize on `stopCapture()`

Fixed in `ef8f034` (2026-03-11).

**Symptom:** saved `video.mov` unreadable, "cannot open" error.
**Cause:** the moov atom is unwritten when `stopCapture()` returns.
**Fix:** call `removeRecordingOutput()` **before** `stopCapture()`, then `await` the
`didFinishRecordingTo:` delegate via `CheckedContinuation` before touching the file.
Applies to **both** stop and pause flows.

**Rule:** never access an `SCRecordingOutput` file until `didFinishRecordingTo:` has fired.

Later refinement (2026-06-10): `finalizeAndStop()` must **not** discard an
already-finalized MOV when `stopCapture()` throws.

---

### L6. WAV must be 16-bit signed integer PCM

Fixed in `6864973` (2026-06-05).

**Symptom:** "Audio conversion failed" — no recording saved.
**Cause:** `AVAudioEngine` delivers 32-bit float by default; `AVAssetExportSession`
**rejects float-PCM WAVs**.
**Fix:** write WAV with explicit 16-bit signed int PCM; if M4A conversion still fails,
log and save the raw WAV so a recording is never lost.

**Guard:** covered by a unit test — `AudioRecorder.wavWriteSettings` is `nonisolated static`
specifically so `AudioRecorderSettingsTests.swift` can assert it. Do not "simplify" that
signature back to instance-isolated.

---

### L7. Bluetooth headsets change the audio format mid-recording

Fixed in the PR #12 line (2026-06-10), lives in `MeetingAgent/Recording/AudioRecorder.swift`.

**Symptom:** silent audio file + empty live transcript, Bluetooth headphones only.
**Cause:** engaging the BT mic renegotiates **A2DP→HFP**, changing the `AVAudioEngine`
input format mid-session. `AudioRecorder` wrote with `try?` into a WAV fixed at the
*initial* format — every post-switch write failed **silently**.
**Fix:** observe `.AVAudioEngineConfigurationChange`, reinstall the tap on the new format,
convert buffers via `AVAudioConverter` back to the WAV's original processing format,
restart the engine unless user-paused. Converted buffers also feed the live transcriber
so each recognition request sees one consistent format.

Related: `saveMeeting` preserves the `.wav` extension on the fallback path (it was
misnaming WAV data as `audio.m4a`); retranscribe looks for both.

**Guard:** the `try?` swallowing write errors is what made this invisible for weeks.
Do not reintroduce silent failure in the write path — QA with Bluetooth headphones
specifically, not just built-in mic.

---

### L8. `SCStreamConfiguration` needs an explicit audio format

Same round as L7. When `capturesAudio = true`, you must set `sampleRate = 48000` and
`channelCount = 2` explicitly, or capture fails with "invalid parameter."

---

### L9. `captureMicrophone = true` breaks sandboxed screen recording

Fixed in `95ada19` (2026-05-04).

**Symptom:** every frame dropped, "stream output NOT found."
**Cause:** `captureMicrophone` makes ScreenCaptureKit build an aggregated HAL virtual
device (system audio + mic). In a sandboxed app, HAL daemon communication fails
(`HALC_ShellDevice::RebuildControlList`).
**Fix:** removed `captureMicrophone`. Screen recordings still capture system audio via
`capturesAudio`.

Second half of the same commit: `SCStream` was created with `delegate: nil`, so internal
stream errors were **silently swallowed**. Now passes `self` as `SCStreamDelegate` so
`didStopWithError` surfaces to the UI. **Do not pass `nil` again.**

---

### L10. Exactly one `MeetingManager` instance

Fixed in `b3e03a9` (2026-05-04).

**Symptom:** `BuiltInMicrophoneDevice` I/O failures, XPC disconnect from ScreenCaptureKit,
"stream output NOT found" on screen recording.
**Cause:** `MeetingAgentApp` created an `onboardingManager` unconditionally *and*
`ContentView` created a second `@StateObject MeetingManager`. Both called
`startMonitoring()` and held the audio device; the idle onboarding instance had already
claimed the mic.
**Fix:** a single manager owned by `MeetingAgentApp`, passed via `@ObservedObject` to both
`OnboardingView` and `ContentView`.

**Guard:** never add a second `@StateObject MeetingManager`. Any new view takes it as
`@ObservedObject`/`@EnvironmentObject`.

---

### L11. Local checkout drifting behind origin

2026-07-21: the "invalid parameter" screen-recording failure (L7) was re-diagnosed from
scratch before anyone noticed the local `main` was **5 commits behind `origin/main`** —
the fix already existed upstream.

**Guard:** before debugging any symptom listed in this file, run `git status` and
`git log origin/main..main` first. Confirm you are actually running the fixed code.

---

### L12. Branch from the most recent feature branch

Phase 2.4 hit a "buttons disappeared" bug caused purely by branching from a stale base.
Always branch new work from the newest feature branch, not an older one.

---

### L13. Speaker diarization plumbing — REMOVED 2026-08-04, see the deferral note below

> **Deferred.** Speaker diarization and macOS live transcription were removed on 2026-08-04
> to get to a working app. `SpeakerDiarization.swift`, `SpeakerLabelingView.swift`,
> `LiveTranscriber.swift`, and `SpeakerClustererTests.swift` are deleted; restore point is
> the parent of that commit. The `SFVoiceAnalytics` + k-means approach below is **retired**,
> not paused — diarization will be rebuilt on Argmax SpeakerKit (see Part 4). The entry stays
> because the two silent-failure modes it documents are the kind a rewrite can reintroduce.



Two independent silent failures fixed in `6344464` (2026-03-11):

1. The labeling sheet **never appeared** — `.sheet` was attached to `inlineNotesPanel`,
   which only exists while recording. Moved to the `RecordingView` body.
2. Voice analytics were **never collected** — the code cancelled the `SFSpeechRecognizer`
   task immediately after `endAudio()` instead of waiting for the final result.
   Must await the final result.

Also: `c7b6329` moved off the deprecated `SFTranscriptionSegment.voiceAnalytics` to
`SFSpeechRecognitionMetadata.voiceAnalytics`, mapping frame-level analytics back to
segments by timestamp proportion.

> Note: `CLAUDE.md` still claims the deprecated API is "used intentionally." That is
> **stale** — `c7b6329` migrated off it. See Part 3.

---

### L14. iOS shares code via symlinks — by design

`deep-state/Shared/` contains symlinks to `../../MeetingAgent/Shared/*.swift`.

This is **not** an accident to be "cleaned up." The project uses
`PBXFileSystemSynchronizedRootGroup` (objectVersion 77), where target membership is
**folder-based, not file-based** — you cannot add an individual file from the macOS sync
folder to the iOS target.

Moving files *within* the macOS sync folder means repointing symlinks but requires no
pbxproj edits. Converting symlinks to real target membership is invasive and best done in
Xcode's UI. Programmatic pbxproj edits need the `xcodeproj` ruby gem (v1.27).

The test target requires `DEVELOPMENT_TEAM = 472CR4BT3B` (same as the app) or the xctest
bundle fails to dlopen into the host app.

---

### L15. `installTap` format mismatch → hard FAULT on Bluetooth input

Observed 2026-08-04 17:13:53:

```
AVAEUtility.mm:176  Format mismatch:
  input hw      <AVAudioFormat 1 ch, 16000 Hz, Float32>
  client format <AVAudioFormat 1 ch, 44100 Hz, Float32>
Failed to create tap due to format mismatch
FAULT: com.apple.coreaudio.avfaudio
```

Stack: `AudioRecorder.installTap(format:)` ← `handleConfigurationChange()` ← `start()`.

**Cause.** `handleConfigurationChange()` (`AudioRecorder.swift:160`) reads
`engine.inputNode.outputFormat(forBus: 0)` and immediately reinstalls the tap with it.
When a Bluetooth headset renegotiates **A2DP → HFP**, the hardware drops to 16 kHz mono,
but `outputFormat` can still report the stale 44.1 kHz client format for a short window.
Installing a tap whose format disagrees with the bus raises an **Objective-C `NSException`**,
not a Swift error — `try?` cannot catch it, so it terminates the process.

This is the same A2DP→HFP trigger as **L7**; L7 fixed the *silent-write* half, L15 is the
*tap-install* half that L7's reinstall path introduced. Independent of L1 — this is a format
race in our own code, not an entitlement problem.

**Fixed in `e55b2be`:**
- `installTap()` now passes `format: nil`, so AVAudioEngine reads the bus's own current
  format at install time instead of a snapshot that may already be stale.
- `handleConfigurationChange()` stops the engine before removing and reinstalling the tap,
  so the format cannot move underneath the install, then restarts unless user-paused.
- Buffer conversion to the WAV's processing format was already handled in the tap closure
  and is unchanged — the converter is reset so it rebuilds from the new input format.
- Logs the new sample rate / channel count on every reconfiguration.

**Guard:** QA audio-only recording with a Bluetooth headset connected *and* actively
switching profiles — this never reproduces on the built-in mic.

---

### L16. `Image("Inner Robot Eye 1")` — appiconset members are not named images

```
No image named 'Inner Robot Eye 1' found in asset catalog   [SwiftUI / Invalid Configuration]
```

`MeetingAgent/Assets.xcassets/` contains `AccentColor.colorset`, `AppIcon.appiconset`,
and `Icon Status Badge.iconbadgeset` — and **zero imagesets**. `Image(_:)` resolves names
against imagesets only, so there is nothing to match.

`Inner Robot Eye 1.png` does exist, but `AppIcon.appiconset/Contents.json` registers it as
the `mac / 512x512 / 2x` **icon slot**. An appiconset compiles to a single icon resource
and its member files are not individually addressable — not by `Image(_:)`, not by
`NSImage(named:)`. The file being visible in the folder is what makes this confusing.

**Cause:** the icon rework deleted `deep-state-logo.imageset`, `Image.imageset`, and
`Image 1.imageset`, then repointed both call sites from `Image("deep-state-logo")` to
`Image("Inner Robot Eye 1")` — a name that only ever existed as an app-icon filename.

**Affected:** `ContentView.swift:19` (32×32 header logo) and `OnboardingView.swift:88`
(80pt welcome-screen logo). Cosmetic only — SwiftUI renders an empty placeholder.

**Fix:** create `Assets.xcassets/Inner Robot Eye 1.imageset/` with a `Contents.json`
pointing at the PNG (source art is in `MeetingAgent/img/`). No code change needed.
Downscale first — the source is ~1 MB at roughly 1024², for slots rendered at 32pt/80pt.

**Guard:** an app icon is never a general-purpose image. If a view needs the logo, it needs
its own imageset.

---

### L17. `'WhisperKit' is missing a dependency on 'ArgmaxCore'`

```
'WhisperKit' is missing a dependency on 'ArgmaxCore' because dependency scan of
Swift module 'WhisperKit' discovered a dependency on 'ArgmaxCore'
```

**This is not a missing dependency you can add.** `ArgmaxCore` is an internal *target* of
`argmax-oss-swift`, not a published *product*. The package vends only `ArgmaxOSS`,
`WhisperKit`, `TTSKit`, `SpeakerKit`, `argmax-cli`, and `whisperkit-cli` — there is no
`ArgmaxCore` product to select in Xcode's package picker. SPM resolves it transitively;
a healthy build log shows `➜ Explicit dependency on target 'ArgmaxCore' in project
'argmax-oss-swift'`.

The message comes from Xcode's **explicit modules** dependency scanner
(`SWIFT_ENABLE_EXPLICIT_MODULES = YES`, on by default). It generally means a stale module
cache or package-graph state in the IDE, not a project misconfiguration — clean
command-line builds of both targets pass with the same project file.

**Fix order — cheapest first:**
1. Xcode → File → Packages → **Reset Package Caches**, then Product → **Clean Build Folder**.
2. Quit Xcode, delete the project's `DerivedData` folder, reopen.
3. If DerivedData was deleted while Xcode was closed, package resolution can come back
   corrupted (`DecodingError.dataCorrupted … not valid JSON`). Repair with:
   ```bash
   xcodebuild -resolvePackageDependencies -project "Deep State Meeting Agent MacOS.xcodeproj" -scheme "deep state Meeting Agent"
   ```
4. Only if it survives all of the above is it a real graph problem.

**Related misconfiguration, fixed 2026-08-04.** The macOS app target linked `whisperkit-cli`
— an **executable** product — alongside `WhisperKit`. Nothing in the source imports it
(`ArgmaxCLI`/`WhisperKitCLI` appear nowhere), and the iOS target correctly linked only
`WhisperKit`. Linking an executable product into an app target pulls `ArgmaxCLI` and its
argument-parser dependencies into the module graph for no benefit. Removed.

**Guard:** the app targets should link `WhisperKit` only. When diarization lands, add
`SpeakerKit` — never a `*-cli` product.

---

### L18. SwiftUI views must observe `StorageManager`, not reach through the singleton

**Symptom:** in onboarding, picking a local folder left GET STARTED greyed out forever, and
SAVE TO iCLOUD appeared to do nothing. Both buttons were working — the view just never redrew.

**Cause:** `OnboardingView` declared `@ObservedObject var manager: MeetingManager` but read
`StorageManager.shared` directly at each use site (10 of them). `StorageManager` is an
`ObservableObject`, but reading a singleton inside `body` registers **no SwiftUI dependency**,
so `@Published` changes to `rootURL` and `storageMode` never invalidated the view.
`.disabled(StorageManager.shared.rootURL == nil)` therefore kept its stale `true`.

**Fix:** hold it as `@ObservedObject private var storage = StorageManager.shared` and go
through that property.

**Guard:** any view whose state depends on `StorageManager` (or any other shared
`ObservableObject`) must declare it as a property wrapper. `StorageManager.shared.<x>` inside
a `body` is the bug signature — grep for it.

**Related:** this masked L3. Even with the fix, the iCloud path stayed broken until the
entitlements came back, because `rootURL` genuinely was nil. Two independent faults presenting
as one dead button. The step now shows why iCloud is unavailable instead of failing silently.

---

## Part 2 — Chronological changelog

47 commits, 2026-01-27 → 2026-07-23. `▲` marks a commit that introduced a regression.

### Foundation (Jan–Mar 2026)
| Commit | Date | Change |
|---|---|---|
| `37f5720` | 01-27 | Initial MVP — macOS audio transcription |
| `46ddfc8` | 02-07 | Images |
| `094101f` | 02-09 | Fix Info.plist crash on permission check |
| `a26c5f8` `04b2467` | 02-19 | Documentation dir; `/init` |
| `a1f79bd` | 02-24 | Icons; docs relocated |
| `bd88846` | 02-24 | Fix MainActor reference error |
| `5fab4c9` | 03-02 | **v1.1 — audio-only recording mode.** Live transcription works here (no SCK conflict) |
| `0498df8` | 03-05 | `.gitignore`; untrack Xcode user data |

### Phase 2 — recording UX (Mar 2026)
| Commit | Date | Change |
|---|---|---|
| `3bfa341` | 03-06 | 2.1 pause/resume (audio via `AVAudioEngine`; screen via segmented SCStream + `AVMutableComposition`); dark-mode color fixes |
| `29d1e1b` | 03-06 | 2.2 meeting notes sheet |
| `6031fb6` `75c3dcb` `f34e07f` | 03-06 | 2.3 meeting title → `transcript.md` header; folder stays a timestamp |
| `f48538b` | 03-06 | 2.4 library view |
| `99a2d1e` | 03-06 | NOTES toggle, inline panel replaces sheet |
| `f72bd1c` | 03-08 | 2.5 speaker diarization (k-means++, elbow-method k, `VoicePrintStore`); window resizability |
| `c7b6329` | 03-08 | **L13** — migrate off deprecated `voiceAnalytics` |
| `ef8f034` | 03-11 | **L5** — SCRecordingOutput finalization |
| `6344464` | 03-11 | **L13** — diarization sheet + analytics collection; file import; retranscribe; LLM framework |
| `7d8d4c0` | 03-11 | Persist LLM summary into `transcript.md` |
| `2474233` | 03-12 | Extract `SharedModels` / `TranscriptViewModel` for iOS |

### iOS target + the sandbox war (May 2026)
| Commit | Date | Change |
|---|---|---|
| `6b66d6b` `a449415` | 05-04 | iOS target, `StorageManager`, iCloud sync. **Origin of the iCloud entitlements later lost in L3** |
| `3d709d5` | 05-04 | **L1** — added the audioanalyticsd exception |
| `95ada19` | 05-04 | **L9** — drop `captureMicrophone`; wire `SCStreamDelegate` |
| `b3e03a9` | 05-04 | **L10** — single `MeetingManager` |
| `c4aa1ab` | 05-07 | Further screen-recording fixes |

### Calendar + the big refactor (Jun 2026)
| Commit | Date | Change |
|---|---|---|
| `c92d316` | 06-05 | 3.3 calendar integration, auto-start, attendee name suggestions |
| `6864973` | 06-05 | **L6** — 16-bit int PCM WAV; logo; onboarding reset |
| `b9d002a` | 06-07 | `PROJECT_STATUS.md` baseline |
| `9dc4b2d` | 06-07 | Phase 1 cleanups; `SUPPORTED_PLATFORMS` → macosx |
| `30bf809`…`0ea2b44` | 06-07 | Phases 2a–2f — extract `PermissionsService`, `AmbientLevelMonitor`, `WhisperTranscriber`, `ScreenRecorder`, `LiveTranscriber`, `AudioRecorder`, `FileImportService` |
| `d1b8d00` | 06-07 | Phase 3 — test target, 8 tests (incl. the L6 guard) |
| `df417ee` `d6b34b2` | 06-08 | Phase 4 — `MeetingAgent/` into feature folders; symlinks repointed (**L14**) |
| `369bee8` | 06-09 | MeetingManager update |
| — | 06-10 | TestFlight QA round: **L7**, **L8**, L5 refinement. L1 removal experiment → crash |

### Release prep (Jul 2026)
| Commit | Date | Change |
|---|---|---|
| `6419c0d` | 07-03 | Directory refactor; **added the L1 explanatory comment** |
| `e57064e` ▲ | 07-12 | iOS settings screens + share audio. **Silently destroyed the L1 comment and all iCloud entitlements on both targets (L2, L3)** |
| `89e787c` ▲ | 07-21 | Project status + test renames. **Introduced the L4 bundle-ID drift** (fixed same day) |
| `9995fab` | 07-21 | Merge PR #12 |
| `1493f9d` | 07-23 | README |
| uncommitted | 07-21 | **Removed** audioanalyticsd + `app-sandbox` keys (L1) |
| — | 08-04 | Removal runtime-verified; **L1 settled — entitlement stays out** |

---

## Part 4 — Planned: diarization via Argmax SpeakerKit

Replacement for the retired `SFVoiceAnalytics` + k-means path (L13). Not started — this is a
decision record so the evaluation is not redone from scratch.

**Package.** As of May 2026 Argmax merged WhisperKit into a single package,
[`argmax-oss-swift`](https://github.com/argmaxinc/argmax-oss-swift), shipping WhisperKit +
SpeakerKit (pyannote diarization) + TTSKit together.

**Why this one.** The project already depends on `argmaxinc/WhisperKit` tracking `main`. Same
vendor, same repo, same SPM manifest going forward — adding diarization is closer to enabling
a product than vetting and integrating a new third-party library.

**Model.** pyannote-v4 (community-1): segmentation + embedding + clustering as one CoreML
pipeline, on Apple Silicon / ANE.

**Platform floor.** macOS 13.0+ / iOS 16.0+ — both under this project's existing macOS 14+
floor, so no deployment-target change.

**Licensing.** SDK is MIT/Apache-2.0. The underlying pyannote weights are **CC-BY-4.0**, which
requires attribution — a credits or About-screen line. Not a blocker for commercial use, but
it is a shipping requirement, so budget the UI for it.

**Open gap.** No published DER/EER numbers for SpeakerKit specifically — Argmax has not put out
a benchmarks doc the way FluidAudio has. **Spike required**: measure directly against real
meeting audio before committing. Do not assume parity with published pyannote numbers.

**Sequencing.** Ship a working app first. Then: dependency swap → measurement spike → wire
diarization → rebuild the labeling UI.

---

## Part 3 — Open items

1. ~~L1 is unresolved~~ — **settled 2026-08-04.** The entitlement is removed, removal is
   runtime-verified, and it stays out. Only remaining task is committing it (item 3).
2. **L3 iCloud entitlements are still missing.** This is an active, committed regression
   and the highest-value thing left to fix.
3. **The uncommitted entitlements change needs an explicit commit.** Right now the single
   most-relitigated decision in the project exists only as an unexplained dirty file —
   which is precisely why it keeps looking like it reverted itself.
4. **`build/MeetingAgent.xcarchive`** (2026-06-10) misrepresents current entitlements and
   has already caused confusion twice. Preserve its dSYMs if you still need to symbolicate
   the June TestFlight build, then regenerate it.
5. **Stale `CLAUDE.md` claims** to correct:
   - says `SFTranscriptionSegment.voiceAnalytics` is "used intentionally" — `c7b6329` migrated off it
   - says "There are no tests in this project currently" — there are 4 test files
   - references the old `deep state Meeting Agent.xcodeproj` name; the project is now
     `Deep State Meeting Agent MacOS.xcodeproj`
   - references a `documentation/` directory that does not exist in this checkout
6. **Orphaned App Store Connect record** from the L4 upload needs manual deletion.
7. **Local husk:** an untracked `deep state Meeting Agent.xcodeproj/` remains (only
   `xcuserdata` + `project.xcworkspace`, no `project.pbxproj`). Harmless but confusing —
   safe to delete locally.

---

## Pre-commit checklist

```bash
git diff -- '*.entitlements'                                    # L2, L3
grep -n PRODUCT_BUNDLE_IDENTIFIER *.xcodeproj/project.pbxproj   # L4
git log origin/main..main                                       # L11
```

Before any upload, additionally inspect the **signed binary's** entitlements (L1) and
manually exercise: screen+audio recording, audio-only recording, Bluetooth-headset
recording (L7), and iCloud sync (L3).
