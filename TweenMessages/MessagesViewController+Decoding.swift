import UIKit
import SwiftUI
import Messages
import MapKit
import CoreLocation
import os

// Decoding + the effective-received rules (split from MessagesViewController.swift
// — structure plan R1; extension = same type, new file).
extension MessagesViewController {
    // MARK: - Decoding

    /// Decodes a bubble's payload into `received` and refreshes the cached
    /// participant roster + agreement state from the message.
    ///
    /// Each received bubble carries the full participant list, so the most
    /// recent message is the canonical snapshot — we replace, not merge. The
    /// single-peer cache key is still written so legacy host-app code paths
    /// keep working until Slice 6 migrates them.
    @discardableResult
    func decodeAndCache(_ message: MSMessage?, in conversation: MSConversation) -> Bool {
        guard let message, let url = message.url, let state = TweenState(url: url) else { return false }
        if message.senderParticipantIdentifier == conversation.localParticipantIdentifier {
            // Own bubble: never decoded as inbound state — but if it's a
            // staged .leave/.agree the user sent AFTER this extension was
            // torn down (didStartSending never fired), this tap is the only
            // proof it went out. Commit it now, or the leaver stays "in" on
            // their own device forever (post-push audit backstop).
            commitStagedSendIfNeeded(state, conversation: conversation)
            return false
        }
        // Revision guard (T1 old-bubble resurrection): every bubble is a
        // canonical roster snapshot, so without ordering, tapping an OLDER
        // bubble re-adopted its stale roster verbatim — a leaver popped back
        // "in". Ignore anything older than the newest revision seen for this
        // chat. Rev-less payloads (older builds, host-app sends) keep the
        // legacy trust-the-tap semantics.
        let revisionKey = conversationKey ?? Self.conversationKey(for: conversation)
        if let revision = state.revision {
            // Older-than-floor bubbles reject; AT the floor only the sender
            // who set it (or any .invite — concurrent joins must union) is
            // accepted — concurrent same-revision place mints by another
            // device don't (W2 tie-break; messageType threads the exception).
            guard ConversationMeetupStore.shouldAcceptInbound(
                revision: revision, senderID: state.senderID,
                messageType: state.messageType, key: revisionKey) else {
                logger.debug("Ignoring stale bubble rev=\(revision, privacy: .public)")
                return false
            }
            ConversationMeetupStore.noteRevision(revision, sender: state.senderID, key: revisionKey)
        }
        received = effectiveReceived(decoded: state)
        logger.debug("Decoded incoming Tween message type=\(state.messageType.rawValue, privacy: .public) participants=\(state.participants.count, privacy: .public) agreed=\(state.agreedNames.count, privacy: .public)")

        // Persist / clear the agreed-meetup cache based on the new state:
        //   - .agree fully agreed → persist (terminal state survives extension restarts)
        //   - .counter → clear (counter restarts negotiation, prior agreement is undone)
        //   - others → leave the cache alone
        if state.messageType == .agree, state.isFullyAgreed {
            LocationCache.saveAgreedMeetup(state)
            if let conversationKey {
                ConversationMeetupStore.saveAgreed(state, key: conversationKey)
            }
        } else if state.messageType == .counter {
            LocationCache.clearAgreedMeetup()
            if let conversationKey {
                ConversationMeetupStore.saveProposed(state, key: conversationKey)
            }
        } else if state.messageType == .leave {
            if state.participants.isEmpty {
                LocationCache.clearAgreedMeetup()
                if let conversationKey {
                    ConversationMeetupStore.clearProposalState(key: conversationKey)
                }
            }
        } else if state.kind == .place, let conversationKey {
            ConversationMeetupStore.saveProposed(state, key: conversationKey)
        }

        // Roster adoption is a MERGE, not a replace (group-session semantics:
        // the conversation is a standing meetup people join and leave freely).
        // The incoming list is one sender's view — treating it as canonical
        // let a leave→rejoin bubble carrying `[me]` wipe the whole group on
        // every device that tapped it. Joins/updates merge additively; only
        // an explicit `.leave` removes (its sender), and departure tombstones
        // keep the removal sticky against rosters from peers who never
        // processed the leave — until that person's own rejoin lifts theirs.
        let senderKeys = RosterMerge.senderKeys(senderID: state.senderID, senderName: state.senderName)
        // Absorb gossiped departures — minus the local user, whose own
        // presence is governed solely by the localUserLeft tombstone.
        let myKeys: Set<String> = [localParticipantID(), Self.localParticipantName()]
        ConversationMeetupStore.noteDeparted(state.departed.filter { !myKeys.contains($0) },
                                             key: revisionKey)
        if state.messageType == .leave {
            ConversationMeetupStore.noteDeparted(senderKeys, key: revisionKey)
        } else {
            ConversationMeetupStore.clearDeparted(senderKeys, key: revisionKey)
        }

        // The local user's own entry after they've left still gets the
        // dedicated tombstone filter: peers who never tapped the leave bubble
        // keep broadcasting this user in their rosters (a bubble is only
        // processed when tapped, and nobody taps "X is out" — they just read
        // it). Without it, any later bubble silently re-adds the leaver.
        var incomingRoster = state.participants
        if ConversationMeetupStore.localUserLeft(key: revisionKey) {
            let myName = Self.localParticipantName()
            let myId = localParticipantID()
            let legacyID = conversation.localParticipantIdentifier.uuidString
            incomingRoster.removeAll { $0.matches(id: myId, name: myName) || $0.id == legacyID }
        }
        if !incomingRoster.isEmpty || state.messageType == .leave {
            let known = currentParticipants.isEmpty ? activeSnapshotParticipants() : currentParticipants
            let merged = RosterMerge.merge(
                local: known,
                incoming: incomingRoster,
                messageType: state.messageType,
                senderKeys: senderKeys,
                departed: ConversationMeetupStore.departedParticipants(key: revisionKey))
            currentParticipants = merged
            LocationCache.saveParticipantSnapshot(merged, localContext: localParticipantContext())
            saveParticipantsForActiveConversation(merged)
        }

        // Legacy single-peer cache: write the most recent NON-LOCAL coordinate
        // so OnboardingView's polling keeps animating. The name comparison MUST
        // use the same fallback the host app uses (UserName.fallback = "You");
        // without it, when UserProfile.displayName is nil, every participant's
        // non-nil name wins the != comparison and the first entry — possibly
        // the LOCAL user — leaks into the peer cache. That was Bug #4.
        let myName = Self.localParticipantName()
        let myId = localParticipantID()
        if let peer = state.participants.first(where: { !$0.matches(id: myId, name: myName) }) {
            LocationCache.savePeer(peer.coordinate, isActive: true)
            logger.debug("Saved peer coordinate lat=\(peer.latitude, privacy: .public) lon=\(peer.longitude, privacy: .public)")
            return true
        } else if !state.participants.isEmpty || state.messageType == .leave {
            LocationCache.setPeerActive(false)
        }
        // Legacy fallback for pre-group bubbles where participants[] is empty.
        // We trust state.participantCoordinate here because the sender filtered
        // out their own message via senderParticipantIdentifier (guard above) —
        // so this coord IS the remote user's.
        if state.participants.isEmpty, let peerCoord = state.participantCoordinate {
            LocationCache.savePeer(peerCoord, isActive: true)
            return true
        }
        logger.debug("Incoming message had no non-local participant; peer cache untouched")
        return false
    }

    /// The local user's display name, with the same fallback the host app
    /// uses. Centralised so every name-based filter agrees on what counts as
    /// "me" — drifting between call sites was the root of Bug #4.
    static func localParticipantName() -> String {
        UserProfile.displayName ?? UserName.fallback
    }

    /// The durable identity stamped into every payload this device emits.
    /// Was `activeConversation?.localParticipantIdentifier` — but that UUID is
    /// device-scoped (a peer can never match it) and re-mintable. The stable
    /// install ID survives conversations, renames, and reinstalls of state.
    func localParticipantID() -> String {
        TweenIdentity.stableID
    }

    /// The conversation-scoped UUID this device stamped into payloads BEFORE
    /// the stable install ID existed. Used only to filter this user's own
    /// legacy roster entries during the transition.
    func legacyLocalParticipantID() -> String? {
        activeConversation?.localParticipantIdentifier.uuidString
    }

    static func conversationKey(for conversation: MSConversation) -> String {
        ConversationMeetupStore.conversationKey(
            localID: conversation.localParticipantIdentifier.uuidString,
            remotes: conversation.remoteParticipantIdentifiers.map(\.uuidString))
    }

    /// Mints the next outgoing payload revision for the active conversation.
    /// Deliberately NOT recorded here: the revision is noted by deliverBubble
    /// only once the bubble is actually sent/staged. Recording at mint time
    /// meant every failed or cancelled send burned a revision, and after two
    /// of those the peer's genuinely-new bubbles decoded as "stale" and were
    /// silently dropped. Nil (legacy semantics) when no conversation is known.
    func nextOutgoingRevision() -> Int? {
        guard let conversationKey else { return nil }
        return ConversationMeetupStore.lastRevision(key: conversationKey) + 1
    }

    func activeSnapshotParticipants() -> [Participant] {
        guard let conversationKey,
              let snapshot = ConversationMeetupStore.load(key: conversationKey)
        else { return [] }
        return snapshot.participants
    }

    func saveParticipantsForActiveConversation(_ participants: [Participant]) {
        guard let conversationKey else { return }
        ConversationMeetupStore.saveParticipants(participants, key: conversationKey)
    }

    func localParticipantContext() -> LocalParticipantContext {
        LocalParticipantContext(id: localParticipantID(),
                                name: Self.localParticipantName())
    }

    var isLocalUserInCurrentConversation: Bool {
        let context = localParticipantContext()
        let participants = currentParticipants.isEmpty ? activeSnapshotParticipants() : currentParticipants
        return participants.contains(where: { $0.matches(context) })
    }

    // MARK: - Effective received state
    //
    // The bubble the user tapped (`conversation.selectedMessage`) tells us
    // what THEY were looking at, but the SOURCE OF TRUTH for the meetup is
    // the most recent agreement — which lives in App Group via
    // LocationCache.{save,load}AgreedMeetup. If they tap an old propose
    // after agreeing, we still want to show MEETUP SET, not Agree/Change.

    /// Resolves the effective `received` state for rendering, applying the
    /// "agreed meetup is sticky" rule on top of whatever decodeAndCache
    /// produced. The decoded value still drives peer/participant cache writes
    /// (those happen inside decodeAndCache); this only changes what
    /// ExpandedView is handed.
    func effectiveReceived(decoded: TweenState?) -> TweenState? {
        // Conversation-scoped agreement ONLY when we know which conversation
        // we're in. The device-global LocationCache fallback is reserved for
        // the keyless case — falling back to it whenever the scoped store had
        // no agreement leaked chat A's MEETUP SET into chat B.
        let agreedCandidate: TweenState?
        if let conversationKey {
            // The sticky agreement never applies to a user who LEFT this
            // conversation's meetup — the stored agreed state stays alive for
            // the remaining group (and a rejoin), but this device is out and
            // must not be bounced back into MEETUP SET (post-push audit).
            agreedCandidate = ConversationMeetupStore.localUserLeft(key: conversationKey)
                ? nil
                : ConversationMeetupStore.load(key: conversationKey)?.agreedState
        } else {
            agreedCandidate = LocationCache.loadAgreedMeetup()
        }
        guard let agreed = agreedCandidate, agreed.isFullyAgreed else {
            return decoded
        }
        // Nothing selected — show the agreement so the user lands on the
        // terminal state regardless of which bubble iOS happens to pick.
        guard let decoded else { return agreed }
        // User tapped the propose/counter that led to this agreement — show
        // MEETUP SET (sameSpot match means it's literally the bubble that
        // was agreed to).
        if decoded.kind == .place, Self.sameSpot(decoded, agreed) {
            return agreed
        }
        // Different spot, an invite, etc. — trust the user's tap.
        return decoded
    }

    /// Two TweenStates point at the "same" spot when their coordinates match
    /// within a tight epsilon. 1e-4 degrees is ~11 m at the equator — well
    /// inside any GPS jitter, well outside any float-roundtrip noise from
    /// `coordinateString`'s %.6f formatting.
    static func sameSpot(_ a: TweenState, _ b: TweenState) -> Bool {
        a.sameSpot(as: b)   // shared epsilon — see TweenState.sameSpot(as:)
    }

    /// Builds the next outgoing participant list by removing any prior entry
    /// for the local user and appending a fresh one with the current coordinate.
    /// New payloads preserve the iMessage participant UUID, with name fallback
    /// only for legacy bubbles.
    func nextParticipantList(myCoord: CLLocationCoordinate2D,
                                     conversation: MSConversation?) -> [Participant] {
        let myName = Self.localParticipantName()
        let myId = localParticipantID()
        // Entries this device minted BEFORE the stable install ID existed
        // carry the conversation-scoped UUID; drop those too or the user
        // duplicates themselves the first time they act on an older roster.
        let legacyID = conversation?.localParticipantIdentifier.uuidString
        let scoped = currentParticipants.isEmpty ? activeSnapshotParticipants() : currentParticipants
        let source = scoped.isEmpty ? [] : scoped
        let others = source.filter { !$0.matches(id: myId, name: myName) && $0.id != legacyID }
        let needsRide = source.first(where: { $0.matches(id: myId, name: myName) || $0.id == legacyID })?.needsRide ?? false
        let me = Participant(id: myId, name: myName, coordinate: myCoord, needsRide: needsRide)
        return others + [me]
    }

    func participantListWithoutMe() -> [Participant] {
        let myName = Self.localParticipantName()
        let myId = localParticipantID()
        let legacyID = legacyLocalParticipantID()
        let scoped = currentParticipants.isEmpty ? activeSnapshotParticipants() : currentParticipants
        let source = scoped.isEmpty ? [] : scoped
        return source.filter { !$0.matches(id: myId, name: myName) && $0.id != legacyID }
    }

}
