# Alternative Solution: Post-Recording Transcription

## The Problem

Your app is trying to use the microphone in **TWO ways simultaneously**:

1. **ScreenCaptureKit** → Records screen + microphone to .mov file
2. **AVAudioEngine** → Captures microphone for live transcription

This creates an **audio session conflict** on macOS, which causes the abort crash.

## Solution: Transcribe After Recording (More Reliable)

Instead of live transcription, extract the audio after recording and transcribe it.

### Benefits:
✅ No audio session conflicts
✅ More reliable
✅ Better transcription quality
✅ Uses the already-recorded audio
✅ No additional microphone access needed

## Implementation

Replace the current transcription approach with this:

### Option 1: Use WhisperKit (Already in Your Project)

The `whisper` property is already set up but not being used. Use it to transcribe the extracted audio:

```swift
func stopAndTranscribe() async {
    statusMessage = "Stopping..."
    
    do {
        try await stream?.stopCapture()
        isRecording = false
        
        guard let videoURL = lastRecordingURL else { 
            statusMessage = "No recording found"
            return 
        }
        
        statusMessage = "Extracting audio..."
        
        // Extract audio from the .mov file
        guard let audioURL = try await extractAudio(from: videoURL) else {
            statusMessage = "Failed to extract audio"
            return
        }
        
        statusMessage = "Transcribing with AI..."
        
        // Use WhisperKit to transcribe
        let transcriptText = await transcribeWithWhisper(audioURL: audioURL)
        
        statusMessage = "Saving files..."
        
        // Save all three files
        saveTranscript(text: transcriptText, videoURL: videoURL, audioURL: audioURL)
        
        // Clean up
        try? FileManager.default.removeItem(at: videoURL)
        try? FileManager.default.removeItem(at: audioURL)
        
    } catch {
        statusMessage = "Processing failed: \(error.localizedDescription)"
        print("❌ Stop error: \(error)")
        isRecording = false
    }
}

private func transcribeWithWhisper(audioURL: URL) async -> String {
    guard let whisper = whisper else {
        return "AI model not loaded"
    }
    
    do {
        let result = try await whisper.transcribe(audioPath: audioURL.path)
        return result?.text ?? "No speech detected"
    } catch {
        print("❌ Transcription error: \(error)")
        return "Transcription failed: \(error.localizedDescription)"
    }
}
```

### Option 2: Use Apple's Speech Recognition (Post-Recording)

```swift
private func transcribeWithSpeech(audioURL: URL) async -> String {
    guard let recognizer = SFSpeechRecognizer() else {
        return "Speech recognizer not available"
    }
    
    let request = SFSpeechURLRecognitionRequest(url: audioURL)
    request.requiresOnDeviceRecognition = true
    
    return await withCheckedContinuation { continuation in
        recognizer.recognitionTask(with: request) { result, error in
            if let result = result, result.isFinal {
                continuation.resume(returning: result.bestTranscription.formattedString)
            } else if let error = error {
                continuation.resume(returning: "Transcription error: \(error.localizedDescription)")
            }
        }
    }
}
```

## What to Remove

Since we're not doing live transcription anymore, remove these:

### Remove from MeetingManager.swift:

1. **Delete these properties:**
```swift
// DELETE THESE:
@Published var liveTranscript = ""
private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
private var recognitionTask: SFSpeechRecognitionTask?
private var audioEngine: AVAudioEngine?
```

2. **Delete these functions:**
- `startLiveTranscription()`
- `stopLiveTranscription()`

3. **Remove these calls from start():**
```swift
// DELETE THIS LINE:
try startLiveTranscription()
```

4. **Remove these calls from stopAndTranscribe():**
```swift
// DELETE THIS LINE:
stopLiveTranscription()
```

### Remove from ContentView.swift:

Delete the entire live transcript display section:

```swift
// DELETE THIS ENTIRE SECTION:
if manager.isRecording {
    VStack(alignment: .leading, spacing: 8) {
        HStack {
            Image(systemName: "waveform")
                .foregroundStyle(.blue)
            Text("Live Transcript")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        
        ScrollView {
            Text(manager.liveTranscript.isEmpty ? "Listening..." : manager.liveTranscript)
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(6)
        }
        .frame(height: 80)
        
        // Voice visualizer
        VoiceVisualizer(amplitudes: manager.amplitudes)
    }
    .transition(.opacity)
}
```

Replace with:
```swift
if manager.isRecording {
    VStack(alignment: .leading, spacing: 8) {
        HStack {
            Image(systemName: "record.circle")
                .foregroundStyle(.red)
            Text("Recording in progress...")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        
        // Voice visualizer
        VoiceVisualizer(amplitudes: manager.amplitudes)
    }
    .transition(.opacity)
}
```

## Why This Is Better

✅ **No crashes** - No audio session conflicts
✅ **Simpler code** - Fewer moving parts
✅ **More reliable** - One audio source at a time
✅ **Better quality** - Can use higher quality transcription models
✅ **Works offline** - Both WhisperKit and Apple's on-device recognition work offline

## Testing

1. Remove the live transcription code
2. Add the post-recording transcription
3. Test recording
4. After stopping, you'll see "Transcribing with AI..."
5. The transcript.md will contain the transcribed text

---

**Recommendation**: Try this approach first. It's much more stable and reliable than trying to do live transcription while recording.
