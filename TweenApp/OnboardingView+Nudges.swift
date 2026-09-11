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
                proNudgeReason = .engagement
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
    /// Sends a referral invite: a Tween bubble through the Messages composer
    /// (from inside Friends, as its child sheet). No composer (iPad without
    /// Messages, the simulator): the share sheet with the App Store link.
    func sendReferralInvite() {
        ensureNamed {
            guard ReferralInvite.canSendBubble,
                  let message = ReferralInvite.makeMessage(senderName: UserProfile.displayName) else {
                if case .friends = activeSheet {
                    friendsSubSheet = .invite
                } else {
                    UIPasteboard.general.string = ReferralInvite.bodyText
                    showToast("Invite copied — paste it to a friend")
                }
                return
            }
            presentMessageCompose(PendingMessage(
                recipients: [],
                body: ReferralInvite.bodyText,
                message: message,
                onSent: {
                    Referrals.noteInviteSent()
                    referralSnapshot = ReferralStore.load()
                    flashReferral("Invite sent ✓ — it counts when they join")
                }))
        }
    }

    func flashReferral(_ text: String) {
        withAnimation(Tokens.Motion.snappy) { referralFlash = text }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            withAnimation(Tokens.Motion.snappy) {
                if referralFlash == text { referralFlash = nil }
            }
        }
    }

    /// Every App Group refresh: pick up referrals the extension counted, and
    /// celebrate them once — on the home screen, where a toast is visible.
    /// Inside Friends the card updates live instead, and the announcement
    /// waits for the sheet to close.
    func refreshReferrals() {
        let fresh = ReferralStore.load()
        if fresh != referralSnapshot { referralSnapshot = fresh }
        guard activeSheet == nil, tourStep == nil else { return }
        var state = fresh
        if let until = state.grantedUntil, ReferralPolicy.grantActive(state),
           state.announcedGrantUntil != until {
            state.announcedGrantUntil = until
            state.announcedReferralCount = state.referrals.count
            ReferralStore.save(state)
            referralSnapshot = state
            showToast("\(ReferralPolicy.required) friends joined — Tween Pro is yours for 3 months 🎉")
        } else if state.referrals.count > state.announcedReferralCount {
            state.announcedReferralCount = state.referrals.count
            ReferralStore.save(state)
            referralSnapshot = state
            let progress = ReferralPolicy.progress(state)
            showToast("A friend joined from your invite — \(progress) of \(ReferralPolicy.required) toward free Pro")
        }
    }
}

// MARK: - The Pro ad

extension OnboardingView {
    /// Shows an ad earned by a hand-off to Maps or a return visit, once the
    /// home screen is free: not during the tour, not over a sheet (the place
    /// sheet the user left for Maps stays until they close it).
    func presentProAdIfDue() {
        guard tourStep == nil, activeSheet == nil, EngagementStore.load().proAdPending else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard tourStep == nil, activeSheet == nil else { return }
            var state = EngagementStore.load()
            let show = NudgePolicy.takeProAd(in: &state, proUnlocked: ProEntitlement.isUnlocked, now: Date())
            EngagementStore.save(state)
            guard show else { return }
            proNudgeReason = .welcomeBack
            proNudgeShowing = true
            activeSheet = .proNudge
        }
    }
}
