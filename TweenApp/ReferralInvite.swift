import SwiftUI
import Messages
import MessageUI

/// Builds the invite you send from Friends or the paywall: a real Tween
/// bubble, not plain text. A friend without Tween gets Messages' own "get
/// the app" treatment on it; once they install and tap it, their Tween
/// offers one tap to tell you they joined — which is what counts the
/// referral (see `ReferralPolicy`).
enum ReferralInvite {
    static let appStoreURL = "https://apps.apple.com/app/id6782279087"

    /// Rides along as the message text: the only thing an SMS recipient
    /// sees, and a direct link for anyone the bubble alone doesn't convince.
    static var bodyText: String {
        "I'm using Tween to find fair places to meet. Get it, then tap my Tween invite so it counts 🎁 \(appStoreURL)"
    }

    /// For the share sheet, when there's no Messages composer (an iPad
    /// without iMessage): no bubble is sent, so don't mention one.
    static var shareText: String {
        "I'm using Tween to find fair places to meet — get it here: \(appStoreURL)"
    }

    static var canSendBubble: Bool { MFMessageComposeViewController.canSendText() }

    @MainActor
    static func makeMessage(senderName: String?) -> MSMessage? {
        let invite = ReferralMessage(kind: .invite, senderID: TweenIdentity.stableID,
                                     senderName: senderName)
        guard let url = invite.encodedURL() else { return nil }
        let layout = MSMessageTemplateLayout()
        layout.image = ReferralBubbleArt.render(.invite)
        layout.caption = senderName.map { "\($0) invited you to Tween" } ?? "You're invited to Tween"
        layout.subcaption = "Fair places to meet, picked by travel time"
        let message = MSMessage(session: MSSession())
        message.url = url
        message.layout = layout
        message.summaryText = layout.caption
        return message
    }
}

/// Identifiable wrapper so a sheet can present the composer for one invite.
struct ReferralInviteDraft: Identifiable {
    let id = UUID()
    let message: MSMessage
}
