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
        #if DEBUG
        // Demo hooks for Pro-gated surfaces: force the cached entitlement so
        // screenshots can show either side of the gate without a purchase.
        if CommandLine.arguments.contains("-DEMO_PRO_UNLOCKED") {
            ProEntitlement.setUnlocked(true)
        } else if CommandLine.arguments.contains("-DEMO_PRO_LOCKED") {
            ProEntitlement.setUnlocked(false)
        }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                // Initial entitlement check + the app-lifetime purchase/refund
                // listener. The extension never does StoreKit work — it reads
                // the cached flag this keeps fresh.
                .task { ProEntitlement.activate() }
        }
    }
}
