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
        // During the tour: count, but don't decide. Deciding stamps the
        // nudge shown and rolls the next threshold, so a pop-up that came
        // due on the tour's own I'm in was burned unseen (audit 2026-09-08).
        guard tourStep == nil else {
            state.count(event)
            EngagementStore.save(state)
            return
        }
        let nudge = NudgePolicy.record(event, in: &state, proUnlocked: ProEntitlement.isUnlocked)
        EngagementStore.save(state)
        guard let nudge else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard activeSheet == nil, tourStep == nil else { return }
            switch nudge {
            case .pro:
                proNudgeShowing = true
                activeSheet = .proNudge
            case .review:
                requestReview()
            }
        }
    }

    /// The Pro pop-up went away — Not now or a swipe-down, counted once from
    /// the host sheet's onDismiss. Two of these move it to the long cooldown.
    func noteProNudgeDismissed() {
        var state = EngagementStore.load()
        NudgePolicy.noteProDismissed(in: &state)
        EngagementStore.save(state)
    }
}
