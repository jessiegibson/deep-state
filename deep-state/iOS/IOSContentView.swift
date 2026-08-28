import SwiftUI

enum IOSAppTab { case record, library }

struct IOSContentView: View {
    @StateObject private var manager = IOSMeetingManager()
    @State private var activeTab: IOSAppTab = .record
    @State private var isSettingsOpen = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image("AppIcon")
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 32, height: 32)
                Text("Meeting Agent")
                    .font(NBDesign.headlineFont)
                Spacer()
                HStack(spacing: 0) {
                    tabChip("REC", tab: .record)
                    tabChip("LIBRARY", tab: .library)
                }
                Button {
                    isSettingsOpen = true
                } label: {
                    Image(systemName: "gear")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(NBDesign.background)
                }
                .padding(8)
                .overlay(Rectangle().stroke(NBDesign.background.opacity(0.3), lineWidth: NBDesign.thinBorder))
                .padding(.leading, 8)
            }
            .padding(NBDesign.padding)
            .background(NBDesign.foreground)

            Divider()

            switch activeTab {
            case .record:
                IOSRecordingView(manager: manager)
            case .library:
                IOSLibraryView(manager: manager)
            }

            VersionFooter()
        }
        .background(NBDesign.background)
        .sheet(isPresented: $isSettingsOpen) {
            LLMSettingsView(settings: LLMSettings.shared)
        }
        .onAppear {
            if activeTab == .library { manager.loadLibrary() }
        }
    }

    private func tabChip(_ label: String, tab: IOSAppTab) -> some View {
        Button(label) {
            if tab == .library { manager.loadLibrary() }
            activeTab = tab
        }
        .font(NBDesign.captionFont)
        .foregroundStyle(activeTab == tab ? Color.primary : Color.primary.opacity(0.5))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(activeTab == tab ? NBDesign.background : Color.clear)
        .overlay(
            Rectangle()
                .stroke(NBDesign.border, lineWidth: activeTab == tab ? NBDesign.thinBorder : 0)
        )
        .buttonStyle(.plain)
    }
}
