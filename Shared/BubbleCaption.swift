import Foundation
import Messages

/// Per-MessageType caption + subcaption applied to an iMessage bubble's layout.
///
/// Shared by both the iMessage extension (when sending bubbles from inside
/// Messages) and the host app (when pre-filling MFMessageComposeViewController
/// with a Tween-styled MSMessage for the ping flow). Lives in Shared/ so the
/// copy stays in lockstep across targets.
enum BubbleCaption {
    static func apply(to layout: MSMessageTemplateLayout,
                      state: TweenState,
                      totalSeats: Int) {
        let name = state.senderName ?? "Someone"
        let totalKnown = max(totalSeats, state.participants.count, 1)
        let inCount = state.participants.count

        switch state.messageType {
        case .invite:
            if inCount <= 1 {
                layout.caption = "\(name) wants to meet up!"
                layout.subcaption = "Tap to find a fair spot"
            } else {
                layout.caption = "\(name) is in! (\(inCount) of \(totalKnown) ready)"
                layout.subcaption = "Tap to find fair spots"
            }

        case .leave:
            // The subcaption must EARN the tap: a leave is only processed by
            // whoever taps the bubble (nothing runs on the peers' devices), so
            // "1 still ready" left everyone's map stale — nobody taps a status
            // line. Point at the updated plan instead.
            layout.caption = "\(name) is out"
            layout.subcaption = inCount > 0 ? "Tap for the updated plan" : "Tap to start over"

        case .propose:
            layout.caption = "\(name) suggests \(state.text)"
            layout.subcaption = "Tap to see the route"

        case .agree:
            if state.isFullyAgreed {
                layout.caption = "✓ Meeting at \(state.text)"
                layout.subcaption = "Tap for directions"
            } else {
                // `name` (from senderName) is the original proposer — the
                // most recent agreer is `agreedNames.last`. Sanitise it so an
                // un-named agreer reads as "Friend", never the "You" fallback
                // (audit F2: agreedNames is encoded without outgoingName()).
                let agreer = state.agreedNames.last.map(UserName.peerDisplayName) ?? "Your friend"
                let needed = max(state.participants.count - 1, 1)
                let have = state.agreedIDs.isEmpty ? state.agreedNames.count : state.agreedIDs.count
                layout.caption = "\(agreer) agrees to \(state.text) (\(have) of \(needed))"
                let missing = state.missingAgreementNames(excluding: nil, name: "")
                if !missing.isEmpty {
                    layout.subcaption = "Waiting for \(missing.joined(separator: ", "))"
                } else {
                    layout.subcaption = "Tap to confirm"
                }
            }

        case .counter:
            layout.caption = "\(name) suggests \(state.text) instead"
            layout.subcaption = "Tap to see the route"
        }
    }
}
