# MeetingAgent Project Status

Snapshot date: 2026-06-25
Branch reviewed: refactor/structure (HEAD: 369bee8, plus uncommitted working-tree changes)
Repo: github.com/jessiegibson/deep-state
Shipping target this cycle: macOS app (com.soloai.deepState) to TestFlight

## How to read this file

This is the single source of truth for project state. Update it at the end of any
work session using the process in the last section. The June 5 version of this file
was 20 days stale and described a pre-refactor layout that no longer exists. Keeping
it current is cheaper than reconstructing state from git each time.

## 1. Branches

Only two branches exist. The old `feature/calendar-integration` and `feature/ios`
branches referenced in earlier notes are already merged and gone.

- `main` — last commit 7 weeks ago (c4aa1ab). Pre-refactor. Contains the merged iOS
  target and the screen-recording fixes. Do not ship from here.
- `refactor/structure` — current branch, 13 commits ahead of `main`, 0 behind. This
  is the live line of work and the branch to ship from. Last commit 2 weeks ago,
  with uncommitted working-tree changes on top (see section 5).

## 2. What shipped since the last snapshot

The MeetingManager monolith split (previously the top refactor item) is essentially
done. Commit history on `refactor/structure`:

- Phase 1: low-risk cleanups
- Phase 2a: extract PermissionsService, remove dead summarization
- Phase 2b: extract AmbientLevelMonitor
- Phase 2c: extract WhisperTranscriber
- Phase 2d: extract ScreenRecorder
- Phase 2e: extract LiveTranscriber and AudioRecorder
- Phase 2f: extract FileImportService
- Phase 3: add MeetingAgentTests target with first unit tests
- Phase 4: reorganize source into Shared/ + feature folders

A test target now exists with four files: AudioRecorderSettingsTests,
SpeakerClustererTests, SummaryTemplateTests, TranscriptFormatterTests. The earlier
"zero tests" status no longer holds.

TestFlight prep has also started: ExportOptions.plist (app-store-connect upload,
team 472CR4BT3B, automatic signing), PrivacyInfo.xcprivacy, and a prior local build/
directory.

## 3. Source layout (current)

The confusing three-name, two-directory layout is mostly resolved on this branch.
Source now lives under MeetingAgent/ in feature folders:

- App/            MeetingManagerApp.swift
- Calendar/       CalendarManager.swift
- Diarization/    SpeakerDiarization.swift, SpeakerLabelingView.swift
- Recording/      MeetingManager.swift, AudioRecorder.swift, ScreenRecorder.swift,
                  LiveTranscriber-related, AmbientLevelMonitor.swift, PermissionsService.swift
- Transcription/  WhisperTranscriber.swift, LiveTranscriber.swift, FileImportService.swift
- Shared/         LLMProvider, LLMSettings(+View), NeobrutalDesign, SharedModels,
                  StorageManager, StorageSettingsView, SummaryTemplates,
                  TranscriptFormatter, TranscriptViewModel, VoiceVisualizer
- Views/          ContentView.swift, OnboardingView.swift

The iOS target source (deep-state/) still exists at repo root and is not the focus
this cycle.

## 4. TestFlight readiness (macOS target)

Verified ready:
- Code signing: Automatic, DEVELOPMENT_TEAM 472CR4BT3B set on all configs.
- Platform: macOS target is SUPPORTED_PLATFORMS = macosx only on both Debug and
  Release. The old stray iphoneos entry is gone.
- Usage strings: mic, camera, speech recognition, calendar, and screen capture are
  all present (some via INFOPLIST_KEY_* build settings merged by GENERATE_INFOPLIST_FILE,
  some in MeetingAgent/Info.plist).
- Entitlements: sandbox, audio input, camera, calendars, user-selected files,
  network client, iCloud (CloudDocuments), and the required audioanalyticsd
  mach-lookup exception. The audioanalyticsd note should be repeated in App Review notes.
- PrivacyInfo.xcprivacy present with UserDefaults and FileTimestamp reason codes.

Fixed today (2026-06-25):
- Build number bumped from CURRENT_PROJECT_VERSION = 1 to 20260625 across all
  configs. A build was already uploaded under build 1, so App Store Connect would
  reject a duplicate. Confirm 20260625 exceeds the last TestFlight build for
  marketing version 1.1 before uploading.
- Added ITSAppUsesNonExemptEncryption = NO to Info.plist. The app uses HTTPS only
  (exempt), so this skips the export-compliance question on every upload.

Still to confirm (cannot be checked from outside Xcode / App Store Connect):
- Release archive builds and signs clean on the Mac. This is the gating step.
- The bumped build number is higher than whatever was last uploaded.
- App Store Connect app record is in TestFlight-ready state with testers assigned.

Note on bundle ID vs iCloud container: bundle ID com.soloai.deepState does not match
container iCloud.soloai.MeetingAgent. This works at runtime as long as the container
exists in the account, but it reads as a mismatch. Leave as-is for this release;
track as a cleanup issue.

## 5. Uncommitted working-tree changes

`refactor/structure` has uncommitted edits to: SpeakerDiarization.swift,
MeetingAgent.entitlements, AudioRecorder.swift, MeetingManager.swift,
ScreenRecorder.swift, StorageManager.swift, FileImportService.swift,
WhisperTranscriber.swift, ContentView.swift, and project.pbxproj. Untracked:
ExportOptions.plist, PrivacyInfo.xcprivacy, MeetingAgentTests/SpeakerClustererTests.swift,
.claude/, and (from today) the build-number and Info.plist edits.

xcodebuild archives the working tree, so these will be in the build whether or not
they are committed. Commit them only after a clean local archive verifies they
compile. Build first, commit second.

## 6. Open backlog (track as GitHub issues)

Features not done:
- 2.2 Transcript editing before save (TranscriptViewModel exists, no edit UI)
- 2.5 Language selection (WhisperKit supports it, no settings UI)
- 3.4 Full-text search across saved transcripts
- 4.2 Export formats (PDF, DOCX, SRT) — currently markdown only
- 4.3 Menu bar mode (NSStatusItem)
- 4.4 App Store prep beyond TestFlight (privacy policy, screenshots, final signing review)

Cleanups / tech debt:
- Reconcile bundle ID com.soloai.deepState vs iCloud container name
- Reconcile CLAUDE.md (outdated bundle ID, references missing documentation/ files,
  predates the refactor)
- Decide on deep-state/ iOS target: bring to parity or formally defer
- Expand test coverage onto the newly extracted units

Phase 5 ideas remain open: SQLite FTS5 search, analytics dashboard, Obsidian export,
smart chapters, batch re-transcribe, webhook integration.

## 7. Update process for this file

Run this at the end of each work session. Keep it lightweight or it stops happening.

1. Capture what changed:
   git log --oneline <last-snapshot-commit>..HEAD
   git status -s
2. Update sections 1-5 to match reality. Adjust the snapshot date and HEAD line at top.
3. Move anything finished out of section 6, and add new known issues discovered.
4. Commit with a clear message:
   git commit -am "docs: update PROJECT_STATUS to <date>"
5. For anything that needs discussion, a deadline, or an owner, open a GitHub issue
   instead of burying it here. This file tracks state. Issues track work.

A repeatable command to start step 1 lives in TESTFLIGHT_RUNBOOK.md and the
status helper script.
