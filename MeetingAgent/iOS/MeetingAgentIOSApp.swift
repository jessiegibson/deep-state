// iOS App Entry Point — only compiled on iOS target.
// To add the iOS target in Xcode:
//   1. File → New → Target → iOS App, name "MeetingAgent iOS", Bundle ID: soloai.MeetingAgentiOS
//   2. Add WhisperKit to this target in Package Dependencies
//   3. Enable iCloud capability → check "iCloud Documents"
//   4. Add iOS/ folder files and shared files (NeobrutalDesign, LLMProvider,
//      LLMSettings, SummaryTemplates, TranscriptFormatter) to the iOS target membership

#if os(iOS)
import SwiftUI

@main
struct MeetingAgentIOSApp: App {
    var body: some Scene {
        WindowGroup {
            IOSContentView()
        }
    }
}
#endif
