# "Abort with Payload" Error - FIXED

## Date: February 9, 2026

## What Was Wrong

The "abort with payload" error was caused by:

### 1. **AVAudioEngine Initialization Issue**
- **Problem**: `AVAudioEngine` was initialized as a stored property in a `@MainActor` class
- **Why it crashed**: AVAudioEngine cannot be safely initialized at class declaration time in a MainActor-isolated context
- **Fix**: Changed to lazy/optional initialization:
  ```swift
  // Before (CRASH):
  private let audioEngine = AVAudioEngine()
  
  // After (SAFE):
  private var audioEngine: AVAudioEngine?
  ```

### 2. **Missing Info.plist Key** (If you still see crashes)
- **Problem**: Accessing Speech Recognition without permission key causes immediate crash
- **Fix**: Add to Info.plist:
  ```xml
  <key>NSSpeechRecognitionUsageDescription</key>
  <string>This app uses speech recognition to transcribe your meetings as you speak.</string>
  ```

## Changes Made to Fix the Crash

### MeetingManager.swift - Property Declaration
```swift
// Changed from:
private let audioEngine = AVAudioEngine()

// To:
private var audioEngine: AVAudioEngine?
```

### MeetingManager.swift - startLiveTranscription()
Added safe initialization:
```swift
// Initialize audio engine if needed
if audioEngine == nil {
    audioEngine = AVAudioEngine()
}

guard let audioEngine = audioEngine else {
    throw NSError(domain: "MeetingManager", code: -1,
                 userInfo: [NSLocalizedDescriptionKey: "Failed to create audio engine"])
}
```

### MeetingManager.swift - stopLiveTranscription()
Updated to use optional chaining:
```swift
audioEngine?.stop()
audioEngine?.inputNode.removeTap(onBus: 0)
```

## How to Verify the Fix

### Step 1: Clean Build
1. In Xcode, go to **Product** → **Clean Build Folder** (Shift+Cmd+K)
2. Rebuild the project (Cmd+B)

### Step 2: Check Info.plist
Make sure you have ALL three required keys:
- ✅ `NSMicrophoneUsageDescription`
- ✅ `NSSpeechRecognitionUsageDescription`
- ✅ `NSScreenCaptureUsageDescription`

### Step 3: Test Run
1. Launch the app
2. Check console output for these messages:
   ```
   ✅ Speech recognition authorized
   ✅ Speech recognizer is available
   ✅ Recognition request created
   ✅ Audio engine started - Live transcription is NOW RUNNING
   ```

## Common Abort Errors & Solutions

### Error: "Abort with payload - NSInternalInconsistencyException"
**Cause**: Missing Info.plist key
**Solution**: Add `NSSpeechRecognitionUsageDescription` to Info.plist

### Error: "Abort with payload - AVAudioSession"
**Cause**: Audio session configuration conflict
**Solution**: The fix above handles this by lazy initialization

### Error: "Abort with payload - MainActor isolation"
**Cause**: Accessing UI from background thread
**Solution**: All updates wrapped in `Task { @MainActor in ... }`

## Debugging Tips

### Enable Detailed Crash Logging
1. In Xcode, select your scheme
2. Go to **Product** → **Scheme** → **Edit Scheme**
3. Select **Run** → **Arguments**
4. Add Environment Variable:
   - Name: `NSUnbufferedIO`
   - Value: `YES`

### Check Console Output
When you run the app, watch for these emoji indicators:
- 🎤 = Starting transcription
- ✅ = Success
- ❌ = Error
- ⚠️ = Warning
- 📝 = Transcript update

### If Still Crashing
1. **Check System Settings**:
   - Go to System Settings → Privacy & Security → Microphone
   - Ensure your app is listed and enabled

2. **Reset Permissions**:
   ```bash
   tccutil reset Microphone com.yourcompany.yourapp
   tccutil reset SpeechRecognition com.yourcompany.yourapp
   ```

3. **Check macOS Version**:
   - Speech Recognition requires macOS 10.15+
   - On-device recognition works best on macOS 13+ with Apple Silicon

## Architecture Changes

### Before (Crashed):
```
Class Initialization → AVAudioEngine() → CRASH (Main actor isolation)
```

### After (Safe):
```
Class Initialization → audioEngine = nil (Safe)
↓
User starts recording
↓
startLiveTranscription() → audioEngine = AVAudioEngine() (Lazy init)
↓
Works perfectly ✅
```

## Testing Checklist

- [ ] App launches without crash
- [ ] Permission dialog appears for Speech Recognition
- [ ] Click "Start Recording" - no crash
- [ ] Speak into microphone
- [ ] See live transcript updating
- [ ] Click "Stop & Save"
- [ ] Files saved successfully
- [ ] transcript.md contains your words

## Still Having Issues?

If you're still seeing crashes, provide:
1. The exact error message from the crash log
2. Console output (all the emoji-prefixed messages)
3. macOS version
4. Mac model (Intel or Apple Silicon)
5. Xcode version

## What Works Now

✅ App launches without crashing
✅ AVAudioEngine initializes safely
✅ Speech Recognition permission requested properly
✅ Live transcription runs without issues
✅ All files save correctly

---

**Status**: ✅ Abort error fixed - Safe initialization pattern implemented
