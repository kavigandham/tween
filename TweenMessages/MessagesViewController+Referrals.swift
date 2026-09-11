import Messages
import UIKit

// Referral bubbles: the invite a friend sends from Tween, and the "I'm on
// Tween" reply that proves this install. See Shared/Referrals.swift.
extension MessagesViewController {
    /// The banner model for the current activation, or nil.
    var referralReplyPrompt: ReferralReplyPrompt? {
        guard let reply = pendingReferralReply else { return nil }
        return ReferralReplyPrompt(inviterName: reply.name,
                                   onReply: { [weak self] in self?.sendReferralReply() })
    }

    /// Handles a tapped or arriving referral bubble. Returns true when the
    /// message WAS one (so the TweenState decode is skipped). Credit happens
    /// here and only here: iMessage vouches the sender is someone else.
    @discardableResult
    func handleReferralBubble(_ message: MSMessage?, in conversation: MSConversation) -> Bool {
        guard let message, let url = message.url,
              let referral = ReferralMessage(url: url) else { return false }
        // My own invite or reply: nothing to count, nothing to answer.
        guard message.senderParticipantIdentifier != conversation.localParticipantIdentifier else {
            return true
        }
        let myID = localParticipantID()
        let events = Referrals.noteInbound(referral, myID: myID,
                                           senderKey: message.senderParticipantIdentifier.uuidString)
        // nil = the inviter never set a name; the banner then says "A friend".
        let name = referral.senderName.map(UserName.peerDisplayName)
        switch referral.kind {
        case .invite:
            if ReferralPolicy.owesReply(ReferralStore.load()) == referral.senderID {
                pendingReferralReply = (referral.senderID, name ?? "")
                sendStatusMessage = nil
            }
        case .joined:
            // The inviter's confirmation, in the chat where it happened.
            let who = name ?? "Your friend"
            let count = events.compactMap { event -> Int? in
                if case .referral(let count) = event { return count } else { return nil }
            }.first
            if events.contains(where: { if case .granted = $0 { return true } else { return false } }) {
                sendStatusMessage = "\(who) is on Tween — \(count ?? ReferralPolicy.required) friends joined. Tween Pro is yours for 3 more months 🎉"
            } else if let count {
                let progress = count % ReferralPolicy.required
                sendStatusMessage = "\(who) is on Tween ✓ — \(progress) of \(ReferralPolicy.required) toward free Pro"
            } else if referral.inviterID == myID {
                sendStatusMessage = "\(who) is on Tween ✓ — already counted"
            }
        }
        return true
    }

    /// Sends the `.joined` bubble back to whoever invited this install —
    /// the proof that it installed. Same direct-send-then-stage path as every
    /// other Tween bubble.
    func sendReferralReply() {
        guard let reply = pendingReferralReply, !isSending,
              let conversation = activeConversation else { return }
        isSending = true
        presentUI(for: presentationStyle)
        sendTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.isSending = false
                self.presentUI(for: self.presentationStyle)
            }
            let myName = UserProfile.displayName
            let joined = ReferralMessage(kind: .joined, senderID: self.localParticipantID(),
                                         senderName: myName, inviterID: reply.inviterID)
            guard let url = joined.encodedURL() else { return }
            let layout = MSMessageTemplateLayout()
            layout.image = ReferralBubbleArt.render(.joined)
            layout.caption = myName.map { "\($0) is on Tween" } ?? "I'm on Tween"
            layout.subcaption = "Tap to count your invite"
            let message = MSMessage(session: MSSession())
            message.url = url
            message.layout = layout
            message.summaryText = layout.caption
            guard !Task.isCancelled else { return }
            do {
                do {
                    try await conversation.send(message)
                    self.sendStatusMessage = reply.name.isEmpty
                        ? "Sent — they'll see you're on Tween."
                        : "Sent — \(reply.name) will see you're on Tween."
                    // Only a bubble that actually went out answers the invite.
                    Referrals.noteReplied(to: reply.inviterID)
                } catch {
                    // Same Direct Send gate as deliverBubble: stage it
                    // instead. It is marked answered in didStartSending,
                    // when the user really sends it — delete it, and the
                    // next tap of the invite offers the reply again.
                    try await conversation.insert(message)
                    self.sendStatusMessage = Self.stagedDeliveryStatus
                }
                self.pendingReferralReply = nil
            } catch {
                self.sendStatusMessage = "Couldn't send. Try again."
            }
        }
    }
}

extension MessagesViewController {
    /// A staged "I'm on Tween" reply that the user just sent for real.
    func commitStagedReferralReplyIfNeeded(_ message: MSMessage) {
        guard let url = message.url, let referral = ReferralMessage(url: url),
              referral.kind == .joined, referral.senderID == localParticipantID(),
              let inviter = referral.inviterID else { return }
        Referrals.noteReplied(to: inviter)
    }
}
