# MeetingAgent (Deep State) - Current Roadmap

Last updated: 2026-02-19

## Current State

The app is an MVP that successfully:
- Records screen + system audio via ScreenCaptureKit
- Extracts audio from the recording (MOV -> M4A)
- Transcribes audio offline using WhisperKit
- Saves organized meeting folders with `transcript.md`, `video.mov`, `audio.m4a`
- Allows the user to pick a save location (persisted via security-scoped bookmarks)
- Shows a voice visualizer during recording

**Known issues:**
- Live transcription is disabled during recording due to audio conflicts with ScreenCaptureKit
- No onboarding/permission walkthrough screens (app relies on system dialogs)
- UI is functional but not yet aligned with the neo-brutalist design vision
- Camera preview view exists but is unused
- No audio-only recording mode (always records screen)
- When WiFi is not available or the WhisperKit doesn't get loaded, not transcription. 
- No Summaries
- Transcription doesn't label speakers.
- Currently doesn't allow to use webcam to take video of the user. 

---

## Phase 1 - Stabilize & Polish (Current Priority)

### 1.1 Audio-Only Recording Mode
Allow recording just the microphone audio without screen capture. This is useful for in-person meetings or phone calls where screen recording isn't needed. This also sidesteps the ScreenCaptureKit audio conflict, enabling live transcription in audio-only mode.

### 1.2 Re-enable Live Transcription
Fix the audio conflict between ScreenCaptureKit and AVAudioEngine. Strategy: use post-recording transcription for screen recording mode, and live transcription (SFSpeechRecognizer) for audio-only mode. This gives the user real-time feedback when screen capture isn't active.

### 1.3 Onboarding & Permission Flow
Build a first-launch walkthrough that guides users through granting:
- Screen recording permission
- Microphone access
- Speech recognition access
- Save folder selection

This should be a step-by-step flow as described in the CLAUDE.md overview. The app should detect which permissions are missing and only prompt for those.

### 1.4 Neo-Brutalist UI Overhaul
Restyle the app to match the neo-brutalist design direction:
- Bold borders, high contrast, raw/blocky layout
- Monospace or display-weight typography
- Minimal color palette with accent colors
- Chunky buttons and clear visual hierarchy
- Remove the default macOS "soft" look

---

## Phase 2 - Core Feature Expansion

### 2.1 Pause/Resume Recording
Add the ability to pause and resume a recording session rather than requiring a full stop and restart.

### 2.2 Transcript Editing Before Save
After recording stops and transcription completes, show the transcript in an editable text view so the user can correct errors before saving.

### 2.3 Meeting Title & Auto-Naming
Let the user set a meeting title. As a fallback, auto-generate a name from the first few words of the transcript or the date/time.

### 2.4 Recording History / Library View
Add a view that lists past recordings with the ability to open the meeting folder, re-read the transcript, or replay the audio/video.

### 2.5 Language Selection
Expose WhisperKit's multi-language support. Let the user choose a transcription language (or auto-detect) from the settings.

---

## Phase 3 - Intelligence & Integrations

### 3.1 AI Meeting Summaries
After transcription, generate a structured summary of the meeting: key topics, action items, decisions made. This should run on-device if possible (using a local model) to maintain the privacy-first approach.

### 3.2 Speaker Diarization
Identify and label different speakers in the transcript (e.g., "Speaker 1:", "Speaker 2:"). WhisperKit may support this or a separate model can be used. 
Create a feature that lets the user label speakers by name.  

### 3.3 Calendar Integration
Use EventKit to pull upcoming calendar events and auto-associate recordings with meetings. Pre-fill meeting titles from calendar event names.

### 3.4 Keyword & Full-Text Search
Allow searching across all saved transcripts by keyword. Index transcripts for fast lookup.
---

## Phase 4 - Platform & Distribution

### 4.1 iCloud Sync / Backup
Allow meeting folders to sync via iCloud Drive so recordings are backed up and accessible across devices.

### 4.2 Export Formats
Support exporting transcripts as PDF, plain text, or SRT (subtitle format for video).

### 4.3 Menu Bar Mode
Add a lightweight menu bar presence so the user can start/stop recordings without opening the full window.

### 4.4 App Store Preparation
Prepare for distribution: proper code signing, sandboxing review, App Store metadata, and privacy policy.


## Future Features
- Allow the user to batch process the transcripts.
- Integrate with Obsidian.
- Develop an iOS mobile application

---

## Phase 5 — New Feature Ideas (2026-03-09)

### 5.1 Full-Text Meeting Search
Search bar in Library view that queries across all saved `transcript.md` files. Index transcripts using SQLite FTS5 or Core Data for sub-second results across thousands of recordings.

### 5.2 Export Formats
One-click export from Library detail view: PDF (formatted with title, date, speaker labels), DOCX, SRT (subtitle format synced to audio timestamps for video review), and plain text.

### 5.3 Menu Bar Mode
`NSStatusItem` presence for quick start/stop without opening the main window. Shows a recording timer in the menu bar and a mini popover with the live transcript snippet.

### 5.4 Calendar Auto-Linking
EventKit integration to pull today's calendar events. Pre-fill meeting title from the active event name. Show upcoming meetings in the recorder as one-tap shortcuts to name the recording.

### 5.5 Meeting Analytics Dashboard
Per-session stats: speaker talk-time pie chart, word count, speaking pace (words/min), and paragraph-level sentiment (positive / neutral / concern). Shown in the Library detail panel.

### 5.6 Obsidian Integration
Export transcript as Obsidian-compatible markdown: YAML frontmatter (date, speakers, tags), wiki-links for speaker names (`[[Alex]]`), and a backlink to the audio file path. One-click export to the user's configured Obsidian vault.

### 5.7 Smart Chapters
Detect topic-shift boundaries in the transcript using an LLM and auto-insert chapter headers (`## Chapter: Budget Discussion`) with anchor links. Useful for long recordings.

### 5.8 Batch Re-Transcribe
Re-run WhisperKit on existing `audio.m4a` files in Library — useful after a model upgrade or when changing the transcription language. Background queue with progress indicator.

### 5.9 Webhook / Zapier Integration
After each recording is saved, POST a JSON payload (title, date, transcript, summary) to a user-configured webhook URL. Enables automation to Slack, Notion, Airtable, Linear, and Zapier.

### 5.10 Rust-Powered Search Index
Full-text search index built in Rust (Swift-Rust FFI via `SwiftRust` or an XPC service) for sub-millisecond search across tens of thousands of meetings. Pre-planned for the Rust integration phase.

