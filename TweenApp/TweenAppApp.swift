import SwiftUI

@main
struct TweenAppApp: App {
    init() {
        // Reset meetup state on cold launch ONLY when nothing live is in
        // flight. This used to run unconditionally from OnboardingView.init,
        // which meant tapping "I'm in" in the iMessage extension and then
        // opening the app silently erased the roster and marked the user out —
        // the exact opposite of the app and extension feeling interchangeable.
        // Harness runs seed their own caches and must not be wiped either.
        let isHarness = CommandLine.arguments.contains { $0.hasPrefix("-HARNESS_HOST") }
        if !isHarness,
           !ConversationMeetupStore.hasLiveMeetup(within: ConversationMeetupStore.snapshotTTL) {
            LocationCache.startFreshMeetup()
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
