# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Run

This is a native macOS SwiftUI app built with Xcode. There is no Package.swift; the project uses an `.xcodeproj` file with Swift Package Manager dependencies.

```bash
# Build from command line
xcodebuild -project MeetingAgent.xcodeproj -scheme MeetingAgent -configuration Debug build

# Run from command line (after building)
open build/Debug/MeetingAgent.app

# Preferred: Open in Xcode and use Cmd+B (build) / Cmd+R (run)
open MeetingAgent.xcodeproj
```

There are no tests in this project currently.

## Architecture

**Pattern**: Single-ViewModel SwiftUI app. `MeetingManager` is the central `@Observable @MainActor` class that owns all state and business logic. Views bind directly to it.

**Key files** (all under `MeetingAgent/`):
- **MeetingManager.swift** (~530 LOC) — Core class handling screen recording, audio capture, live transcription, offline AI transcription, and file management
- **ContentView.swift** — Main UI: folder picker, live transcript display, start/stop controls
- **MeetingManagerApp.swift** — App entry point, WindowGroup setup
- **VoiceVisualizer.swift** — Animated audio level bars (5 bars, color-coded by volume)
- **cameraPreview.swift** — NSViewRepresentable camera preview (currently unused)

**Recording flow**:
1. `start()` → requests ScreenCaptureKit permission → captures display video + system audio to temp MOV file, starts live transcription via `SFSpeechRecognizer` + `AVAudioEngine`
2. `stopAndTranscribe()` → stops capture → extracts audio (MOV → M4A via AVFoundation) → transcribes with WhisperKit → saves organized folder (`meeting-YYYY-MM-DD-HH-mm-ss/` containing `transcript.md`, `video.mov`, `audio.m4a`)

**Dependencies**:
- **WhisperKit** (SPM, tracks `main` branch) — Offline speech-to-text using OpenAI Whisper models
- **ScreenCaptureKit** — Screen/audio recording (requires macOS 14+)
- **Speech framework** — Real-time live transcription
- **AVFoundation** — Audio extraction and processing

## Platform Requirements

- macOS 14.0+ (ScreenCaptureKit requirement)
- Xcode 15+ / Swift 5.0
- Bundle ID: `soloai.MeetingAgent`
- App Sandbox enabled with entitlements for: microphone, camera, calendar, file access, network

## Permissions

The app requires several system permissions configured in both Info.plist and Xcode build settings:
- Screen recording (ScreenCaptureKit)
- Microphone (`NSMicrophoneUsageDescription`)
- Speech recognition (`NSSpeechRecognitionUsageDescription`)
- Camera (`NSCameraUsageDescription`)
- Calendar (`NSCalendarsFullAccessUsageDescription`)

See `documentation/INFO_PLIST_URGENT.md` for permission setup details.

## Known Limitations

- Live transcription is temporarily disabled during recording (causes audio conflict with ScreenCaptureKit) — see `MeetingManager.swift` around line 151
- Save location uses security-scoped bookmarks persisted in UserDefaults

## Documentation

Troubleshooting guides and fix history are in `documentation/`. Key files:
- `COMPLETE_SUMMARY.md` — Feature overview and demo flow
- `TROUBLESHOOTING.md` — Common issues and debugging steps
