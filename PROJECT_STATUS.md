# MeetingAgent Project Status

Snapshot date: 2026-06-05
Branch reviewed: feature/calendar-integration (HEAD: 6864973)

## 1. Why two source directories?

The Xcode project file is `deep state Meeting Agent.xcodeproj`. It contains two native targets, and the source for each lives in its own folder.

deep state Meeting Agent.xcodeproj/
MeetingAgent/      <- source for the macOS target ("deep state Meeting Agent")
deep-state/        <- source for the iOS target ("deep-state")
   iOS/            iOS-only Swift files (IOSContentView, IOSMeetingManager, etc.)
   Shared/         11 symlinks pointing back at MeetingAgent/*.swift
   ContentView.swift     dead. Xcode Hello-World template never deleted.
   deep_stateApp.swift   iOS app entry point
   deep-state.entitlements

The folder named MeetingAgent is the macOS source root and also the owner of every shared Swift file. The iOS target's Shared/ folder reuses those same files through filesystem symlinks. Editing MeetingAgent/StorageManager.swift simultaneously changes the iOS build because iOS reads it through deep-state/Shared/StorageManager.swift.

Three names refer to the same product. The Xcode project is "deep state Meeting Agent". The macOS folder is MeetingAgent. The iOS folder is deep-state. This naming drift is the biggest source of confusion and is worth a one-time cleanup, covered in section 5.

## 2. Targets and bundle identifiers

macOS target name: "deep state Meeting Agent". Bundle ID: com.soloai.deepState. SDK: macosx. SUPPORTED_PLATFORMS includes iphoneos and iphonesimulator (stray, should be macosx only).

iOS target name: "deep-state". Bundle ID: soloai.MeetingAgentiOS. SDK: iphoneos. TARGETED_DEVICE_FAMILY 1,2 (iPhone + iPad).

iCloud container: iCloud.soloai.MeetingAgent. Declared in both entitlements files. Neither bundle ID matches the container name. That works at runtime as long as the container exists in the developer account, but anyone reading the project will assume a mismatch.

CLAUDE.md states Bundle ID: soloai.MeetingAgent. The actual macOS bundle ID is com.soloai.deepState. The doc is wrong.

## 3. Source inventory

macOS-only files (live in MeetingAgent/):
- MeetingManager.swift, 1,294 LOC. Owns screen capture, audio capture, live transcription, post-hoc WhisperKit transcription, LLM summarization, save logic, calendar pre-fill, diarization integration. Monolith.
- ContentView.swift, 744 LOC. Header, RecordingView, calendar panel, notes panel, settings sheet wiring.
- OnboardingView.swift, 251 LOC. 6-step permission walkthrough including new calendar step.
- SpeakerDiarization.swift, 366 LOC. K-means clustering and voice print store.
- SpeakerLabelingView.swift, 257 LOC. Post-recording sheet.
- CalendarManager.swift, 152 LOC. EventKit wrapper with auto-start arming.
- MeetingManagerApp.swift, 37 LOC. App entry point.
- cameraPreview.swift, 30 LOC. NSViewRepresentable. Unused.

Shared files (in MeetingAgent/, symlinked into deep-state/Shared/):
LLMProvider, LLMSettings, LLMSettingsView, NeobrutalDesign, SharedModels, StorageManager, StorageSettingsView, SummaryTemplates, TranscriptFormatter, TranscriptViewModel, VoiceVisualizer.

iOS-only files (live in deep-state/iOS/):
IOSMeetingManager (259 LOC), IOSContentView (69 LOC), IOSRecordingView (131 LOC), IOSLibraryView (131 LOC).

Total: 5,211 lines of Swift across 23 files. Zero tests. Zero TODO or FIXME markers.

## 4. Roadmap status

Done in code (verified against git log and current source):
- 1.1 Audio-only recording mode
- 1.2 Live transcription in audio-only mode (screen-capture mode still uses post-hoc Whisper)
- 1.3 Onboarding and permission flow (6 steps)
- 1.4 Neo-brutalist UI tokens (NBDesign, NBButtonStyle, .nbCard())
- 2.1 Pause/Resume
- 2.3 Meeting title with date fallback
- 2.4 Library view
- 2.5 Speaker diarization with voice print store and labeling sheet (macOS only)
- 3.1 AI meeting summaries (LLMProvider with multiple backends, writes Summarization_transcript.md)
- 3.2 Speaker diarization with naming
- 3.3 Calendar integration with title pre-fill (just landed on feature/calendar-integration)
- 4.1 iCloud sync via CloudDocuments

Not done:
- 2.2 Transcript editing before save. TranscriptViewModel exists but no in-line edit UI before persisting.
- 2.5 Language selection. WhisperKit supports it. No settings UI exposes it.
- 3.4 Full-text search across saved transcripts.
- 4.2 Export formats (PDF, DOCX, SRT). Transcript is markdown only.
- 4.3 Menu bar mode (NSStatusItem).
- 4.4 App Store prep (code signing review, privacy policy, screenshots).

Phase 5 ideas, all open:
- 5.1 SQLite FTS5 search index
- 5.5 Meeting analytics dashboard
- 5.6 Obsidian export
- 5.7 Smart chapters via LLM
- 5.8 Batch re-transcribe
- 5.9 Webhook integration
- 5.10 Rust-powered search

Open bugs from in-session diagnosis:
- Audio conversion previously failed because the WAV was written as 32-bit float PCM and AVAssetExportSession rejects it. Fixed on this branch (commit 6864973) by forcing 16-bit int PCM and adding a raw-WAV fallback save.
- Onboarding never re-runs after the AppStorage flag is set. Fixed on this branch by adding a RESET ONBOARDING button to settings.
- Header logo was not wired. Fixed on this branch.

## 5. What needs to be refactored

These are ordered by payoff per hour of work.

1. Split MeetingManager.swift. 1,294 lines in one @MainActor class makes ownership unclear. Suggested split:
   - AudioRecorder: AVAudioEngine setup, WAV writing, amplitude metering
   - ScreenRecorder: ScreenCaptureKit setup, pause segments, finalization handshake
   - LiveTranscriber: SFSpeechRecognizer rotation and analytics accumulation
   - WhisperTranscriber: WhisperKit setup and post-hoc transcription
   - SummaryService: LLM provider orchestration
   - MeetingSession: a coordinator that owns the above and exposes a single @ObservableObject for views
   Each piece becomes individually testable. Today nothing can be unit tested.

2. Delete deep-state/ContentView.swift. It is the unmodified Xcode template and ships in the iOS binary as dead Swift.

3. Rename folders to match the product. Pick one name. Either rename MeetingAgent/ to macOS/ and deep-state/ to iOS/, or keep MeetingAgent/ and rename deep-state/ to MeetingAgent-iOS/. Update group paths in the pbxproj. This removes the three-name confusion for new contributors.

4. Reconcile bundle IDs and CLAUDE.md. Decide whether the macOS bundle ID is com.soloai.deepState or soloai.MeetingAgent, then update the other end. The doc currently lies.

5. Fix the macOS target's SUPPORTED_PLATFORMS. It currently lists "iphoneos iphonesimulator macosx" for the macOS scheme. Should be macosx only. The iOS target is correctly scoped.

6. Promote iOS to feature parity. iOS is missing:
   - Calendar integration (CalendarManager is macOS-only via #if os(macOS); EventKit works on iOS too)
   - Speaker diarization (SpeakerDiarization.swift is not symlinked into deep-state/Shared/)
   - Speaker labeling sheet
   - LLM summarization wiring inside IOSMeetingManager (the shared LLMProvider is symlinked but iOS may not call it)
   Either symlink the shared files now, or rewrite the platform-specific bits and ship iOS parity as a feature branch.

7. Add a test target. Xcode template includes one by default. Target the testable pieces from refactor 1 (AudioRecorder format settings, TranscriptFormatter output, SpeakerDiarization k-means, SummaryTemplates rendering).

8. Restore or delete the documentation/ directory. CLAUDE.md references documentation/INFO_PLIST_URGENT.md, documentation/COMPLETE_SUMMARY.md, documentation/TROUBLESHOOTING.md. None exist. Either restore the files or drop the references.

9. Remove unused code. cameraPreview.swift is referenced nowhere outside its own file. Either wire it for the webcam-of-user feature (listed in current_roadmap.md known issues) or delete it.

10. Replace shared-file symlinks with an Xcode group reference. Symlinks work on macOS but break on Windows checkouts and confuse tooling. Cleaner pattern: keep one canonical Shared/ folder at the repo root, add the same Swift files to both targets' membership via Xcode's "Target Membership" panel.

11. Update CLAUDE.md. It still references the documentation/ directory, lists an outdated bundle ID, and predates the calendar integration work. Add a short "Phase 3.3" section consistent with the existing Phase 2.x notes.

## 6. Suggested next branch

Given calendar integration just landed, the highest-leverage next move is the MeetingManager split (refactor 1). Doing it now, before more code accretes around the monolith, costs less than doing it after Phase 3.4 search and Phase 4.x export work add another 500 lines.

If you'd rather keep building features, the smallest user-visible win is 2.2 transcript editing before save: TranscriptViewModel already exists and just needs a sheet UI between transcription complete and saveTranscript. Half a day of work.
