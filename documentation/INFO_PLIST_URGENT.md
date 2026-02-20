# Critical Info.plist Setup Instructions

## ⚠️ STOP - Do This First!

The "abort_with_payload" crash is happening because your **Info.plist is missing required permission keys**.

## Step-by-Step: Add Required Permissions

### Method 1: Using Xcode UI (Recommended)

1. **Open your project in Xcode**
2. **Click on your project** in the Project Navigator (top file)
3. **Select your app target** (under TARGETS)
4. **Click the "Info" tab** at the top
5. **Hover over any row** and click the **"+"** button

6. **Add these THREE keys one at a time:**

   **Key 1:**
   - Type: `Privacy - Microphone Usage Description`
   - Value: `This app needs microphone access to transcribe your meetings.`
   
   **Key 2:**
   - Type: `Privacy - Speech Recognition Usage Description`
   - Value: `This app uses speech recognition to transcribe your meetings as you speak.`
   
   **Key 3:**
   - Type: `Privacy - Screen Capture Usage Description`
   - Value: `This app records your screen to capture meeting content.`

### Method 2: Edit Info.plist Directly

If you have an Info.plist file in your project:

1. Find `Info.plist` in Project Navigator
2. Right-click → Open As → Source Code
3. Add these lines inside the `<dict>` tag:

```xml
<key>NSMicrophoneUsageDescription</key>
<string>This app needs microphone access to transcribe your meetings.</string>

<key>NSSpeechRecognitionUsageDescription</key>
<string>This app uses speech recognition to transcribe your meetings as you speak.</string>

<key>NSScreenCaptureUsageDescription</key>
<string>This app records your screen to capture meeting content.</string>
```

## After Adding Keys

1. **Clean Build Folder**: Product → Clean Build Folder (Shift+Cmd+K)
2. **Quit Xcode completely**
3. **Reopen Xcode**
4. **Rebuild** (Cmd+B)
5. **Run the app**

## What You Should See

When you first run the app after adding these keys:
1. macOS will show a dialog asking for **Microphone** permission → Click "OK"
2. macOS will show a dialog asking for **Speech Recognition** permission → Click "OK"
3. The app should then work without crashing

## Still Crashing?

If still crashing after adding Info.plist keys, the issue is likely the **audio conflict** between ScreenCaptureKit and AVAudioEngine trying to use the microphone at the same time.

### Quick Test: Disable Live Transcription Temporarily

In MeetingManager.swift, comment out this line:

```swift
// In start() method around line 125:
// try startLiveTranscription()  // ← Comment this out temporarily
```

Then test if screen recording works without the transcription.

## Why This Happens

Apple **requires** explicit user permission for:
- 🎤 Microphone access
- 🗣️ Speech recognition
- 🖥️ Screen recording

Without the Info.plist keys, the app **crashes immediately** (abort_with_payload) when trying to access these features.

## Verification Checklist

- [ ] Info.plist has `NSMicrophoneUsageDescription`
- [ ] Info.plist has `NSSpeechRecognitionUsageDescription`
- [ ] Info.plist has `NSScreenCaptureUsageDescription`
- [ ] Cleaned build folder
- [ ] Quit and reopened Xcode
- [ ] Rebuilt the app
- [ ] Granted permissions when prompted

---

**Next Step**: Add the Info.plist keys and rebuild. If still crashing, we'll need to see the actual error message from the console.
