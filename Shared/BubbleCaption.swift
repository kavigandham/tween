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
            // Subcaption reads as information, not a raw-link promise: the spot
            // name is in the caption, and the plain-text message stays human.
            layout.caption = "\(name) suggests \(state.text)"
            layout.subcaption = "A fair spot to meet"

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
            layout.subcaption = "A different fair spot"

        // MARK: Poll

        case .pick:
            // The caption is the product here: most people never tap the
            // bubble, they just read the thread. So it has to say what was
            // picked AND that there is now something to vote on.
            layout.caption = "\(name) picked \(state.text)"
            layout.subcaption = boardLine(state: state, totalKnown: totalKnown)
                ?? "Tap to vote or pick your own"

        case .vote:
            layout.caption = "\(name) voted for \(state.text)"
            layout.subcaption = boardLine(state: state, totalKnown: totalKnown)
                ?? "Tap to cast your vote"

        case .decided:
            layout.caption = "✓ Meeting at \(state.text)"
            let votes = state.poll.voteCount(for: state.poll.decidedOptionID ?? "")
            layout.subcaption = votes > 1
                ? "\(votes) votes · Tap for directions"
                : "Tap for directions"

        case .enroute:
            layout.caption = "\(name) is leaving now"
            layout.subcaption = etaLine(state: state)
        }
    }

    /// "Hey Tea 2 · Kung Fu Tea 1 · 3 of 4 voted" — the standings, short
    /// enough for a bubble subcaption. Nil when there's nothing to show yet.
    private static func boardLine(state: TweenState, totalKnown: Int) -> String? {
        let poll = state.absorbedPoll
        guard !poll.options.isEmpty else { return nil }
        let tally = poll.standings.prefix(2).map { entry in
            "\(entry.option.name) \(entry.votes)"
        }.joined(separator: " · ")
        let progress = poll.voteProgress(participants: state.participants)
        let total = max(progress.total, totalKnown)
        guard progress.voted < total else { return tally }
        return "\(tally) · \(progress.voted) of \(total) voted"
    }

    /// "About 12 min away · arriving ~7:24 PM". Falls back to the bare
    /// destination when the sender's build couldn't produce an ETA.
    static func etaLine(state: TweenState) -> String {
        guard let seconds = state.etaSeconds, seconds > 0 else {
            return "On the way to \(state.text)"
        }
        let minutes = max(Int((Double(seconds) / 60).rounded()), 1)
        let arrival = Date().addingTimeInterval(TimeInterval(seconds))
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return "About \(minutes) min away · arriving ~\(formatter.string(from: arrival))"
    }
}
