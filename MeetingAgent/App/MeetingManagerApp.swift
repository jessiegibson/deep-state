//
//  MeetingManagerApp.swift
//  MeetingAgent
//
//  Created by Jessie Gibson on 1/23/26.
//

#if os(macOS)
import SwiftUI

@main
struct MeetingAgentApp: App {
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @StateObject private var manager = MeetingManager()
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            if hasCompletedOnboarding {
                ContentView(manager: manager)
            } else {
                OnboardingView(
                    manager: manager,
                    hasCompletedOnboarding: $hasCompletedOnboarding
                )
            }
        }
        .windowResizability(.contentMinSize)
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
}
#endif
