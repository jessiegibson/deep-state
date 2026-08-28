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
    @State private var screenStatus: PermissionStatus = .notDetermined
    @State private var speechGranted = false
    @State private var calendarGranted = false
    @State private var isRequesting = false

    private let totalSteps = 6

    /// Steps 1–4 explain a system permission before asking for it. App Review
    /// guideline 5.1.1(iv) requires that such a screen ALWAYS leads to the system
    /// prompt: the button must read "CONTINUE" (not "GRANT PERMISSION"), and there
    /// must be no BACK escape hatch that lets the user dismiss the explanation
    /// without the request firing. Rejected on 2026-08-19 for exactly that.
    private var isPermissionStep: Bool { (1...4).contains(currentStep) }

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

            // Navigation buttons. No BACK: a permission explanation screen must not
            // offer a way to back out of the request (guideline 5.1.1(iv)).
            HStack {
                Spacer()

                if isPermissionStep {
                    Button("CONTINUE") {
                        // The screen-recording request re-checks status after a delay, so
                        // this Task is in flight long enough for a second tap to land and
                        // advance twice, skipping a permission entirely.
                        guard !isRequesting else { return }
                        isRequesting = true
                        Task {
                            await requestPermission(forStep: currentStep)
                            isRequesting = false
                            currentStep += 1
                        }
                    }
                    .buttonStyle(NBButtonStyle())
                    .disabled(isRequesting)
                } else if currentStep < totalSteps - 1 {
                    Button("CONTINUE") {
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

            VersionFooter()
        }
        .frame(width: 480, height: 420)
        .background(NBDesign.background)
        .onAppear {
            micGranted = manager.microphonePermissionStatus() == .granted
            screenStatus = manager.screenRecordingPermissionStatus()
            speechGranted = manager.speechRecognitionPermissionStatus() == .granted
            calendarGranted = CalendarManager.shared.checkStatus() == .granted
        }
    }

    // MARK: - Step Views

    private var welcomeStep: some View {
        VStack(spacing: 16) {
            Image("deepStateRobot01")
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
            description: "Deep State records meeting audio on this Mac so it can be saved and transcribed locally.\nmacOS will ask for your permission next.",
            isGranted: micGranted
        )
    }

    private var screenRecordingStep: some View {
        permissionStep(
            icon: "rectangle.dashed.badge.record",
            title: "SCREEN RECORDING",
            description: "Used only when you choose Screen + Audio mode, to record the screen you pick into a video file saved on your Mac.\nmacOS will ask for your permission next.",
            isGranted: screenGranted
        )
    }

    private var speechRecognitionStep: some View {
        permissionStep(
            icon: "waveform",
            title: "SPEECH RECOGNITION",
            description: "Turns your recorded audio into a live transcript. Transcription runs on this device.\nmacOS will ask for your permission next.",
            isGranted: speechGranted
        )
    }

    private var calendarStep: some View {
        permissionStep(
            icon: "calendar",
            title: "CALENDAR",
            description: "Lets Deep State title recordings from the meeting on your calendar and suggest speaker names from its attendees.\nmacOS will ask for your permission next.",
            isGranted: calendarGranted
        )
    }

    // MARK: - Permission Requests

    /// Fires the system permission request for a step. Always called by CONTINUE,
    /// so the explanation screen never becomes a way to avoid the prompt. Already-
    /// granted or previously-denied permissions simply fall through — macOS does not
    /// re-prompt after a decision, and the recorder surfaces a Settings hint at the
    /// point the feature is actually used.
    private func requestPermission(forStep step: Int) async {
        switch step {
        case 1:
            micGranted = await manager.requestMicrophonePermission()
        case 2:
            manager.requestScreenRecordingPermission()
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            screenGranted = manager.screenRecordingPermissionStatus() == .granted
        case 3:
            speechGranted = await manager.requestSpeechRecognitionPermission()
        case 4:
            calendarGranted = await CalendarManager.shared.requestAccess()
        default:
            break
        }
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
        buttonLabel: String = "GRANT PERMISSION",
        note: String? = nil,
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
                    Text("ALREADY GRANTED")
                }
                .font(NBDesign.buttonFont)
                .foregroundStyle(.green)
            }
        }
    }
}
#endif
