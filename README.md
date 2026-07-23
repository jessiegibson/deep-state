# Deep State Meeting Agent

## Overview of Application
This application is a MacOS desktop and iOS application that allows the user to create audio, video, screen recordings while the user is in a meeting, on a video call, walking through documents. 
This application will save the audio recording, transcribe the audio, and if selected record the screen of the user.

The application allows the user to select where they want to save the files. When the application is first installed the application will step through a few screens to ensure that the user provides all of the permissions to their desktop.

Transcription of the audio files should preferably be done on the device using the WhisperKit. This application should allow for the privacy of the user.

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
