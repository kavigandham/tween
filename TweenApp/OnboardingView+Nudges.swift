import SwiftUI
import StoreKit

// The Pro pop-up and the review ask, driven by `NudgePolicy` from the
// moments the app just worked: a join, a spot sent, an agreement.
extension OnboardingView {
    /// Counts a good moment and, when the engine says so, raises the Pro
    /// pop-up or Apple's review prompt — never during the tour, never over
    /// another sheet, and only after the sheet that produced the moment (the
    /// composer, the place sheet) has finished dismissing.
    func noteEngagement(_ event: EngagementEvent) {
        var state = EngagementStore.load()
        let nudge = NudgePolicy.record(event, in: &state, proUnlocked: ProEntitlement.isUnlocked)
        EngagementStore.save(state)
        guard let nudge, tourStep == nil else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard activeSheet == nil, tourStep == nil else { return }
            switch nudge {
            case .pro:
                activeSheet = .proNudge
            case .review:
                requestReview()
            }
        }
    }

    /// "Not now" on the Pro pop-up (or a swipe-down): two of these move the
    /// pop-up to its long cooldown.
    func noteProNudgeDismissed() {
        var state = EngagementStore.load()
        NudgePolicy.noteProDismissed(in: &state)
        EngagementStore.save(state)
    }
}
