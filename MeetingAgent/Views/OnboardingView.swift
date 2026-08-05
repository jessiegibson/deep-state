#if os(macOS)
import SwiftUI

struct OnboardingView: View {
    @ObservedObject var manager: MeetingManager
    /// Must be observed, not reached through `StorageManager.shared` at each use site.
    /// Reading the singleton directly registers no SwiftUI dependency, so `rootURL`
    /// changing after a folder pick never redraws this view and GET STARTED stays disabled.
    @ObservedObject private var storage = StorageManager.shared
    @Binding var hasCompletedOnboarding: Bool

    @State private var currentStep = 0
    @State private var micGranted = false
    @State private var screenGranted = false
    @State private var speechGranted = false
    @State private var calendarGranted = false

    private let totalSteps = 6

    var body: some View {
        VStack(spacing: 0) {
            // Progress bar
            HStack(spacing: 4) {
                ForEach(0..<totalSteps, id: \.self) { step in
                    Rectangle()
                        .fill(step <= currentStep ? NBDesign.foreground : NBDesign.surface)
                        .frame(height: 6)
                        .overlay(Rectangle().stroke(NBDesign.border, lineWidth: 1))
                }
            }
            .padding(.horizontal, NBDesign.padding)
            .padding(.top, NBDesign.padding)

            Spacer()

            Group {
                switch currentStep {
                case 0: welcomeStep
                case 1: microphoneStep
                case 2: screenRecordingStep
                case 3: speechRecognitionStep
                case 4: calendarStep
                case 5: folderSelectionStep
                default: EmptyView()
                }
            }
            .padding(NBDesign.padding)

            Spacer()

            // Navigation buttons
            HStack {
                if currentStep > 0 {
                    Button("BACK") {
                        currentStep -= 1
                    }
                    .buttonStyle(NBButtonStyle(color: NBDesign.surface, textColor: NBDesign.foreground))
                }

                Spacer()

                if currentStep < totalSteps - 1 {
                    Button("NEXT") {
                        currentStep += 1
                    }
                    .buttonStyle(NBButtonStyle())
                } else {
                    Button("GET STARTED") {
                        hasCompletedOnboarding = true
                    }
                    .buttonStyle(NBButtonStyle(color: NBDesign.accent, textColor: .white))
                    .disabled(storage.rootURL == nil)
                    .opacity(storage.rootURL == nil ? 0.5 : 1.0)
                }
            }
            .padding(NBDesign.padding)
        }
        .frame(width: 480, height: 420)
        .background(NBDesign.background)
        .onAppear {
            micGranted = manager.microphonePermissionStatus() == .granted
            screenGranted = manager.screenRecordingPermissionStatus() == .granted
            speechGranted = manager.speechRecognitionPermissionStatus() == .granted
            calendarGranted = CalendarManager.shared.checkStatus() == .granted
        }
    }

    // MARK: - Step Views

    private var welcomeStep: some View {
        VStack(spacing: 16) {
            Image("Inner Robot Eye 1")
                .resizable()
                .scaledToFit()
                .frame(height: 80)

            Text("DEEP STATE")
                .font(.system(size: 28, weight: .black, design: .monospaced))

            Text("Privately record your audio and video from meetings or notes.")
                .font(NBDesign.bodyFont)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
    }

    private var microphoneStep: some View {
        permissionStep(
            icon: "mic.fill",
            title: "MICROPHONE",
            description: "Required to record audio during meetings.",
            isGranted: micGranted,
            action: {
                Task {
                    micGranted = await manager.requestMicrophonePermission()
                }
            }
        )
    }

    private var screenRecordingStep: some View {
        permissionStep(
            icon: "rectangle.dashed.badge.record",
            title: "SCREEN RECORDING",
            description: "Required for Screen + Audio mode.\nYou can skip this if you only plan to use Audio Only mode.",
            isGranted: screenGranted,
            action: {
                manager.requestScreenRecordingPermission()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    screenGranted = manager.screenRecordingPermissionStatus() == .granted
                }
            }
        )
    }

    private var speechRecognitionStep: some View {
        permissionStep(
            icon: "waveform",
            title: "SPEECH RECOGNITION",
            description: "Required for live transcription in Audio Only mode.",
            isGranted: speechGranted,
            action: {
                Task {
                    speechGranted = await manager.requestSpeechRecognitionPermission()
                }
            }
        )
    }

    private var calendarStep: some View {
        permissionStep(
            icon: "calendar",
            title: "CALENDAR",
            description: "Lets the app title recordings automatically and suggest\nspeaker names from meeting attendees.",
            isGranted: calendarGranted,
            action: {
                Task {
                    calendarGranted = await CalendarManager.shared.requestAccess()
                }
            }
        )
    }

    private var folderSelectionStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "icloud.fill")
                .font(.system(size: 48))

            Text("SAVE LOCATION")
                .font(NBDesign.headlineFont)

            Text("Choose where your meeting recordings\nand transcripts will be saved.")
                .font(NBDesign.bodyFont)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            // iCloud option
            Button {
                storage.storageMode = .iCloud
            } label: {
                HStack {
                    Image(systemName: "icloud.fill")
                    Text("SAVE TO iCLOUD")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(NBButtonStyle(
                color: storage.storageMode == .iCloud ? NBDesign.foreground : NBDesign.surface,
                textColor: storage.storageMode == .iCloud ? NBDesign.background : NBDesign.border
            ))

            // Local folder option
            Button {
                storage.storageMode = .local
                manager.selectFolder()
            } label: {
                HStack {
                    Image(systemName: "folder.fill")
                    Text("CHOOSE LOCAL FOLDER")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(NBButtonStyle(
                color: storage.storageMode == .local ? NBDesign.foreground : NBDesign.surface,
                textColor: storage.storageMode == .local ? NBDesign.background : NBDesign.border
            ))

            if let root = storage.rootURL {
                Text(root.lastPathComponent)
                    .font(NBDesign.captionFont)
                    .foregroundStyle(.secondary)
                    .padding(NBDesign.smallPadding)
                    .nbCard()
            } else if storage.storageMode == .iCloud {
                // Never fail silently here — this step blocks GET STARTED, so an
                // unavailable container has to say so rather than look like a dead button.
                Text(storage.iCloudAvailable
                     ? "iCloud Drive is on, but the app's container isn't available yet. Try again, or choose a local folder."
                     : "iCloud Drive is off for this Mac. Turn it on in System Settings → Apple Account → iCloud, or choose a local folder.")
                    .font(NBDesign.captionFont)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(NBDesign.accent)
                    .padding(NBDesign.smallPadding)
                    .nbCard()
            }
        }
    }

    // MARK: - Reusable Permission Step

    private func permissionStep(
        icon: String,
        title: String,
        description: String,
        isGranted: Bool,
        action: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 48))

            Text(title)
                .font(NBDesign.headlineFont)

            Text(description)
                .font(NBDesign.bodyFont)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            if isGranted {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.square.fill")
                    Text("GRANTED")
                }
                .font(NBDesign.buttonFont)
                .foregroundStyle(.green)
            } else {
                Button("GRANT PERMISSION") {
                    action()
                }
                .buttonStyle(NBButtonStyle())
            }
        }
    }
}
#endif
