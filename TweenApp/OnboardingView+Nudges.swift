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

// MARK: - Referrals

extension OnboardingView {
    /// A referral event decoded in THIS process (a friend's bubble opened
    /// from the chat). Grants that land in the extension are announced by
    /// `announcePendingReferralGrant` on the next refresh instead.
    func announceReferral(_ event: ReferralPolicy.Event, from senderName: String?) {
        switch event {
        case .attributed:
            break
        case .referral(let count):
            let who = senderName.map(UserName.peerDisplayName) ?? "A friend"
            showToast("\(who) joined from your invite — \(count % ReferralPolicy.required == 0 ? ReferralPolicy.required : count % ReferralPolicy.required) of \(ReferralPolicy.required)")
        case .granted(let until):
            markReferralGrantAnnounced(until)
            showToast("\(ReferralPolicy.required) friends joined — Tween Pro is yours for 3 months 🎉")
        }
    }

    /// Called from every App Group refresh: a grant the extension awarded is
    /// celebrated once, the next time the app looks.
    func announcePendingReferralGrant() {
        let state = ReferralStore.load()
        guard let until = state.grantedUntil, ReferralPolicy.grantActive(state),
              state.announcedGrantUntil != until else { return }
        markReferralGrantAnnounced(until)
        showToast("\(ReferralPolicy.required) friends joined — Tween Pro is yours for 3 months 🎉")
    }

    private func markReferralGrantAnnounced(_ until: Date) {
        var state = ReferralStore.load()
        state.announcedGrantUntil = until
        ReferralStore.save(state)
    }
}
