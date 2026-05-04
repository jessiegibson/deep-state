//
//  MeetingManagerApp.swift
//  MeetingAgent
//
//  Created by JAG on 1/23/26.
//

#if os(macOS)
import SwiftUI

@main
struct MeetingAgentApp: App {
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @StateObject private var onboardingManager = MeetingManager()
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate 

    var body: some Scene {
        WindowGroup {
            if hasCompletedOnboarding {
                ContentView()
            } else {
                OnboardingView(
                    manager: onboardingManager,
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
