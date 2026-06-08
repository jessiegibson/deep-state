# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.


## Overview of Application
This application is a MacOS desktop application and iOS mobile application that allows the user to create audio, video, screen recordings while the user is in a meeting, on a video call, walking through documents. This application will save the audio recording, transcribe the audio, and if selected record the screen of the user.

The application allows the user to select where they want to save the files. When the application is first installed the application will step through a few screens to ensure that the user provides all of the permissions to their desktop.

Transcription of the audio files should preferably be done on the device using the WhisperKit. This application should allow for the privacy of the user.

## UX/UI Design
The design of this application should be neo-brutalist, using simple navigation. All views must use `NBDesign` tokens exclusively (`NBDesign.padding`, `NBDesign.border`, etc.), `NBButtonStyle`, and `.nbCard()` modifier. See `NeobrutalDesign.swift` for all tokens.

## Build & Run

This is a native macOS SwiftUI app built with Xcode. There is no Package.swift; the project uses an `.xcodeproj` file with Swift Package Manager dependencies. The project file is named `deep state Meeting Agent.xcodeproj`.

```bash
# Build from command line
xcodebuild -project "deep state Meeting Agent.xcodeproj" -scheme "deep state Meeting Agent" -configuration Debug build

# Preferred: Open in Xcode and use Cmd+B (build) / Cmd+R (run)
open "deep state Meeting Agent.xcodeproj"
```

There are no tests in this project currently.

## Architecture

**Pattern**: Single-ViewModel SwiftUI app. `MeetingManager` is the central `@MainActor ObservableObject` class that owns all state and business logic. Views bind directly to it.

**Key files** (all under `MeetingAgent/`):
- **MeetingManager.swift** — Core class handling screen recording, audio capture, live transcription, offline AI transcription, file management, and speaker diarization
- **ContentView.swift** — Main UI with tab-style navigation between recorder and library views. Window is freely resizable with a 640×480 minimum size.
- **MeetingManagerApp.swift** — App entry point, WindowGroup setup with `.windowResizability(.contentMinSize)`
- **StorageManager.swift** — Shared singleton for iCloud + local file storage. Both macOS and iOS targets use this. Handles security-scoped bookmarks (macOS local mode) and iCloud Documents container.
- **StorageSettingsView.swift** — Shared settings UI for choosing iCloud vs local storage mode and subfolder name
- **NeobrutalDesign.swift** — All design tokens (`NBDesign`), `NBButtonStyle`, `NBCardModifier`
- **VoiceVisualizer.swift** — Animated audio level bars (5 bars, color-coded by volume)
- **SpeakerDiarization.swift** — Speaker diarization engine: voice analytics collection, k-means clustering, voice print persistence
- **SpeakerLabelingView.swift** — Post-recording sheet for naming detected speakers
- **cameraPreview.swift** — NSViewRepresentable camera preview (currently unused)

**iOS target** (`deep-state/`):
- **deep_stateApp.swift** — iOS app entry point
- **iOS/IOSMeetingManager.swift** — iOS recording manager (audio-only + WhisperKit)
- **iOS/IOSContentView.swift**, **IOSRecordingView.swift**, **IOSLibraryView.swift** — iOS-specific views
- **Shared/** — Symlinks to shared files in `MeetingAgent/` (StorageManager, NeobrutalDesign, LLM*, etc.)

**iCloud sync**: Both targets use the same iCloud container (`iCloud.soloai.MeetingAgent`). Recordings saved on one device automatically sync to the other via iCloud Documents. The user can configure the subfolder name in Storage Settings.

**Recording flow**:
1. `start()` → requests ScreenCaptureKit permission → captures display video + system audio to temp MOV file
2. Audio-only: `startAudioOnly()` → `AVAudioEngine` tap → writes WAV + feeds `SFSpeechRecognizer` for live transcript + collects `SFVoiceAnalytics` per segment
3. `stopAndTranscribe()` / `stopAudioOnly()` → stops capture → extracts/converts audio → transcribes with WhisperKit → runs speaker diarization → saves organized folder

**Saved folder structure** (timestamp as folder name):
```
2026-03-08 14-30-00/
  transcript.md   ← title, date, notes, diarized transcript
  Summarization_transcript.md   <- title, date, pepole, summarization of the transcript.
  audio.m4a
  video.mov       ← screen recording mode only
```

**transcript.md format** (with speaker diarization):
```markdown
# Meeting Title
2026-03-08 14:30:00

---

## Meeting Notes

<user notes>

---

## Transcript

**Sarah:** The quarterly numbers look strong.

**Alex:** Agreed, let's revisit the timeline.
```

**Dependencies**:
- **WhisperKit** (SPM, tracks `main` branch) — Offline speech-to-text using OpenAI Whisper models
- **ScreenCaptureKit** — Screen/audio recording (requires macOS 14+)
- **Speech framework** — Real-time live transcription + `SFVoiceAnalytics` for speaker diarization
- **AVFoundation** — Audio extraction and processing

## Platform Requirements

- macOS 14.0+ (ScreenCaptureKit requirement)
- Xcode 15+ / Swift 5.0
- Bundle IDs: macOS `com.soloai.deepState`, iOS `soloai.MeetingAgentiOS`
- iCloud container: `iCloud.soloai.MeetingAgent` (shared by both targets; intentionally independent of the bundle IDs)
- App Sandbox enabled with entitlements for: microphone, camera, calendar, file access, network

## Permissions

The app requires several system permissions configured in both Info.plist and Xcode build settings:
- Screen recording (ScreenCaptureKit)
- Microphone (`NSMicrophoneUsageDescription`)
- Speech recognition (`NSSpeechRecognitionUsageDescription`)
- Camera (`NSCameraUsageDescription`)
- Calendar (`NSCalendarsFullAccessUsageDescription`)

See `documentation/INFO_PLIST_URGENT.md` for permission setup details.

## Feature History

### Phase 2.1 — Pause/Resume Recording
- Added pause and resume for both audio-only and screen recording modes
- Screen recording pause creates new segments; segments are merged on stop via `AVMutableComposition`

### Phase 2.2 — Meeting Notes Sheet
- Inline notes panel shown during recording (toggled with NOTES button)
- Notes are prepended to `transcript.md` under `## Meeting Notes`

### Phase 2.3 — Meeting Title
- Optional meeting title field in the notes panel
- Title written as `# Title\ntimestamp` header in `transcript.md`; folder name stays as timestamp

### Phase 2.4 — Recording History / Library
- Library view shows past recordings from the selected save folder
- Recordings listed with title, date, duration
- Buttons disappeared bug: caused by branching from wrong base — always branch new features from the most recent feature branch, not from an older one

### Phase 2.5 — Speaker Diarization (branch: `feature/speaker-diarization`)
- Uses `SFVoiceAnalytics` (pitch, voicing, jitter, shimmer) from `SFTranscriptionSegment` during live recognition
- K-means++ clustering with automatic k-estimation (elbow method, 2–4 speakers) groups similar voices
- `VoicePrintStore` persists mean feature vectors per named speaker in UserDefaults; auto-matches known speakers in future meetings
- Post-recording `SpeakerLabelingView` sheet: shows detected speaker clusters, lets user name each group, provides dropdown of known speaker names
- Labeled transcript saved with `**Name:**` prefixes per turn
- Voice prints updated after each labeled meeting (incremental learning)
- `SFVoiceAnalytics.voiceAnalytics` on `SFTranscriptionSegment` is deprecated in macOS 11.3 (moved to `SFSpeechRecognitionMetadata`) but used intentionally — it's the only API that provides per-segment analytics needed for clustering

### Screen Recording File Finalization Fix
- `SCRecordingOutput` does NOT finalize the MOV file when `stopCapture()` returns — the moov atom is unwritten, making the file unreadable ("cannot open" error)
- Fix: call `removeRecordingOutput()` before `stopCapture()`, then `await` the `didFinishRecordingTo:` delegate callback via `CheckedContinuation` before processing
- This applies to both stop and pause flows — any time we need the recorded file to be valid, we must wait for finalization
- **Rule**: Never access an `SCRecordingOutput` file until the `didFinishRecordingTo:` delegate has fired

### Window Resizability
- Removed fixed `frame(width:height:)` from `ContentView`; replaced with `frame(minWidth:minHeight:)`
- Changed `MeetingManagerApp` to `.windowResizability(.contentMinSize)` so the window can be freely resized

## Known Limitations

- Live transcription is disabled during screen recording mode (audio conflict with ScreenCaptureKit) — see `MeetingManager.swift`
- Speaker diarization only runs in audio-only mode (screen recording uses WhisperKit post-hoc; VAD not applied in real-time for that path)
- Save location uses security-scoped bookmarks persisted in UserDefaults

## Documentation

Troubleshooting guides and fix history are in `documentation/`. Key files:
- `COMPLETE_SUMMARY.md` — Feature overview and demo flow
- `TROUBLESHOOTING.md` — Common issues and debugging steps
