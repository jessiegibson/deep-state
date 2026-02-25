//
//  MeetingManagerApp.swift
//  MeetingAgent
//
//  Created by JAG on 1/23/26.
//

import SwiftUI

@main
struct MeetingAgentApp: App {
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @StateObject private var onboardingManager = MeetingManager()

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
        .windowResizability(.contentSize)
    }
}
