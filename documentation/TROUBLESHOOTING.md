# Troubleshooting "No speech detected" Issue

## ✅ What I Just Fixed

1. **Added the live transcription methods** - They were missing from the code!
2. **Connected start/stop methods** - Now properly calls `startLiveTranscription()` and `stopLiveTranscription()`
3. **Added Speech Recognition permission request** - Was missing from `checkPermissions()`
4. **Added debug logging** - Now prints what's happening

## 🔍 How to Debug

### Step 1: Check the Console Output

When you run the app, look for these messages in Xcode's console:

**On App Launch:**
```
✅ Microphone already authorized
✅ Speech recognition authorized
```

**When you click "Start Recording":**
```
✅ Live transcription started
```

**As you speak:**
```
📝 Transcript updated: Hello world
📝 Transcript updated: Hello world this is a test
```

**When you click "Stop":**
```
⏹️ Stopping live transcription
```

### Step 2: Check Permissions

Open **System Settings** → **Privacy & Security**:

1. ✅ **Microphone** - Your app should be listed and enabled
2. ✅ **Speech Recognition** - Your app should be listed and enabled
3. ✅ **Screen Recording** - Your app should be listed and enabled

### Step 3: Check Info.plist

Make sure these keys are in your `Info.plist`:

```xml
<key>NSMicrophoneUsageDescription</key>
<string>This app needs microphone access to transcribe your meetings in real-time.</string>

<key>NSSpeechRecognitionUsageDescription</key>
<string>This app uses speech recognition to transcribe your meetings as you speak.</string>
```

**To add them in Xcode:**
1. Select your project in the navigator
2. Select your target
3. Go to "Info" tab
4. Click "+" to add entries
5. Type the key name (Xcode will autocomplete)
6. Enter the description

### Step 4: Test Microphone

**Quick microphone test:**

1. Open **System Settings** → **Sound**
2. Go to **Input** tab
3. Speak and watch the input level meter
4. Make sure the correct microphone is selected

### Step 5: Restart the App

After adding Info.plist entries or granting permissions:

1. **Fully quit** the app (Cmd+Q)
2. **Clean build folder** (Shift+Cmd+K in Xcode)
3. **Rebuild** and run

## 🚨 Common Issues & Solutions

### Issue 1: "Speech recognizer not available"
**Console shows:** `⚠️ Recognition error: Speech recognizer not available`

**Solution:**
- Grant Speech Recognition permission
- Restart the app
- Check that your Mac supports on-device recognition (requires macOS 13+)

### Issue 2: Permission prompts not appearing
**Solution:**
- Add Info.plist keys (see Step 3)
- Delete the app and reinstall
- Reset permissions: `tccutil reset Microphone` and `tccutil reset SpeechRecognition` in Terminal

### Issue 3: Microphone input is silent
**Console shows:** No "📝 Transcript updated" messages

**Solution:**
- Check microphone is selected in System Settings → Sound
- Test with Voice Memos app to confirm mic works
- Check input volume is not muted
- Try unplugging/replugging external microphones

### Issue 4: "No speech detected" in transcript
**This means:**
- The app ran but didn't hear any audio
- OR permissions weren't granted
- OR microphone isn't working

**Solution:**
1. Check console for error messages
2. Verify all 3 permissions are granted
3. Test microphone in another app
4. Speak louder or closer to the mic

### Issue 5: Transcript stops updating after 1 minute
**This is expected behavior** - Apple's Speech Recognition has a ~1 minute limit per request.

**Solutions:**
1. **Best:** Restart recognition automatically (I can add this)
2. **Simple:** Record shorter segments
3. **Advanced:** Buffer and restart recognition seamlessly

## 🔧 Advanced Debugging

### Enable Verbose Logging

I've added debug prints. To see them:

1. In Xcode: **View** → **Debug Area** → **Activate Console** (Shift+Cmd+C)
2. Run the app
3. Watch for the emoji prefixed messages:
   - ✅ = Success
   - ❌ = Error
   - ⚠️ = Warning
   - 📝 = Transcript update
   - 🎤 = Microphone related
   - ⏹️ = Stopping

### Test Speech Recognition Separately

Create a simple test to verify Speech works:

```swift
import Speech

func testSpeech() {
    let recognizer = SFSpeechRecognizer()
    print("Available: \(recognizer?.isAvailable ?? false)")
    print("Locale: \(recognizer?.locale.identifier ?? "none")")
}
```

### Check Audio Engine Status

Add this to see if audio engine is running:

```swift
print("Audio Engine Running: \(audioEngine.isRunning)")
print("Input Node: \(audioEngine.inputNode)")
```

## 📋 Checklist

Before reporting issues, check:

- [ ] Info.plist has NSMicrophoneUsageDescription
- [ ] Info.plist has NSSpeechRecognitionUsageDescription
- [ ] Microphone permission granted in System Settings
- [ ] Speech Recognition permission granted in System Settings
- [ ] Microphone is working (tested in Voice Memos or another app)
- [ ] Console shows "✅ Live transcription started" when recording
- [ ] Console shows "📝 Transcript updated" messages when speaking
- [ ] App has been fully restarted after granting permissions
- [ ] Clean build performed (Shift+Cmd+K)

## 🎯 Expected Behavior

### When Working Correctly:

1. **App launches**
   - Console: "✅ Microphone already authorized"
   - Console: "✅ Speech recognition authorized"
   - Status: "Ready"

2. **Click "Start Recording"**
   - Console: "✅ Live transcription started"
   - UI shows live transcript box
   - Status: "Recording..."

3. **Speak into microphone**
   - Console: "📝 Transcript updated: [your words]"
   - UI updates in real-time showing your words
   - Voice visualizer animates

4. **Click "Stop & Save"**
   - Console: "⏹️ Stopping live transcription"
   - Status: "Extracting audio..."
   - Status: "Saving files..."
   - Status: "Saved to meeting-[timestamp]: transcript.md, video.mov, audio.m4a"
   - Transcript file contains your spoken words

## 🆘 Still Not Working?

If you've tried everything above and it's still not working:

1. **Check Console Output** - Copy any error messages
2. **Check Permissions** - Screenshot System Settings → Privacy & Security
3. **Check Info.plist** - Verify the keys are there
4. **Test Microphone** - Confirm it works in Voice Memos
5. **Share Console Logs** - Look for any ❌ or ⚠️ messages

## 🎉 Quick Test

Try this simple test:

1. Launch app
2. Look at console - should see ✅ messages
3. Click "Start Recording"
4. Look at console - should see "✅ Live transcription started"
5. Say "Hello world" clearly into microphone
6. Look at console - should see "📝 Transcript updated: Hello world"
7. Look at UI - should see "Hello world" in the transcript box

If any step fails, that's where the problem is!
