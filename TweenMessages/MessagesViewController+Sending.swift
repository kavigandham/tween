import UIKit
import SwiftUI
import Messages
import MapKit
import CoreLocation
import os

// Compose-and-send paths (split from MessagesViewController.swift).
extension MessagesViewController {
    // MARK: - Sending

    /// Shares the user's location. Uses a fresh cached fix when one is fresh;
    /// otherwise requests one before composing. Sent as an `.invite` bubble
    /// carrying the full participant roster so any recipient can reconstruct
    /// who's in.
    func handleImIn() {
        // Same re-entrancy guard as handleImOut — a double-tap must not emit
        // two .invite bubbles (post-push audit).
        guard !isSending else { return }
        sendTask?.cancel()
        // The chat the user tapped "I'm in" IN, captured before any await —
        // a conversation switch racing the send must not re-point the commit
        // below at the new chat's key (deliverBubble captures its own
        // deliveryKey the same way; post-push verify).
        let sendKey = conversationKey
        sendTask = Task { @MainActor in
            isSending = true
            sendStatusMessage = "Sharing your location..."
            presentUI(for: presentationStyle)

            // Force a fresh fix on every explicit "I'm in" so the bubble
            // carries the user's CURRENT location, not whatever happened to
            // be in the cache (which could be ~5 min old). The cache is only
            // the fallback when CoreLocation can't deliver a fresh fix in
            // time — and even then we'll have warned the user via the status.
            let coordinate: CLLocationCoordinate2D
            if let manual = LocationCache.loadSelf(), manual.isManual == true, LocationCache.isActive {
                // The user declared a future location ("I'll be at…") in the app
                // AND is still active — join with THAT, don't overwrite it with a
                // live GPS fix. A deactivated declaration (after leaving) must NOT
                // be re-shared; fall through to a fresh fix (post-push audit).
                coordinate = manual.coordinate
                logger.debug("Joined with a declared (manual) self location")
            } else if let fresh = await acquireLocation() {
                // Cache the fix but keep the prior active flag — the host app
                // reads LocationCache.isActive as "you're in", so a join must
                // not look successful before the bubble is actually delivered.
                LocationCache.save(fresh, isActive: LocationCache.isActive)
                coordinate = fresh
            } else if LocationCache.isActive, let cached = LocationCache.loadSelf()?.coordinate {
                coordinate = cached
                logger.debug("Used cached self coord (fresh fix unavailable)")
            } else {
                isSending = false
                sendStatusMessage = "Location unavailable. Check permission and try again."
                presentUI(for: presentationStyle)
                return
            }

            let participants = self.nextParticipantList(myCoord: coordinate,
                                                       conversation: self.activeConversation)

            let state = TweenState(
                text: "I'm in",
                latitude: coordinate.latitude,
                longitude: coordinate.longitude,
                senderName: UserProfile.displayName,
                senderID: self.localParticipantID(),
                kind: .participant,
                messageType: .invite,
                participants: participants,
                revision: self.nextOutgoingRevision()
            )
            logger.debug("Encoding I'm in reply participants=\(participants.count, privacy: .public)")
            let didSend = await sendBubbleNow(for: state)
            if didSend {
                // Commit the join only once the bubble is delivered (or staged):
                // a failed send must not leave this device claiming "You're in".
                // deliverBubble already wrote the conversation-scoped roster via
                // recordCanonicalSnapshot.
                LocationCache.setActive(true)
                // Tombstone FIRST: LocationCache's global-mirror writes are
                // dammed while it's set (audit at 69a3886) — joining clears
                // it, then the roster write goes through. Keyed to the chat
                // the send belongs to, not the live ivar.
                if let sendKey {
                    ConversationMeetupStore.setLocalUserLeft(false, key: sendKey)
                }
                // In-memory roster + the global mirror describe the CURRENT
                // chat — adopt them only if we're still in the chat this send
                // started in (a switch already reset them for the new one).
                if self.conversationKey == sendKey {
                    self.currentParticipants = participants
                    LocationCache.saveParticipantSnapshot(participants, localContext: localParticipantContext())
                }
            }
            isSending = false
            if didSend {
                // Preserve the insert-fallback's "tap send to deliver" hint —
                // only clear the status when it's still our in-progress copy.
                if sendStatusMessage == "Sharing your location..." { sendStatusMessage = nil }
            } else if !Task.isCancelled {
                // A backgrounding-cancelled task must not stamp a failure
                // banner for a send the user never saw fail (post-push audit).
                sendStatusMessage = "Couldn't send the Tween message. Try again."
            }
            presentUI(for: presentationStyle)

            // Now that we have a fix, surface the fair spots: jump to expanded
            // (which triggers ranking) and also rank directly to cover the case
            // where we're already expanded and no transition fires. Skip the
            // expand when the bubble was only STAGED — expanding would cover
            // the input field holding the bubble the user still has to send.
            // Only on a real delivery: a failed or conversation-switch-cancelled
            // send must not force-expand and re-rank whatever chat is now active
            // (post-push audit).
            guard didSend, !Task.isCancelled else { return }
            if sendStatusMessage != Self.stagedDeliveryStatus {
                requestPresentationStyle(.expanded)
            }
            kickOffRanking()
        }
    }

    /// Removes the local user from the active roster and sends a canonical
    /// `.leave` snapshot so every recipient stops ranking this participant.
    func handleImOut() {
        // Re-entrancy guard (same as sendAgreedPlace/sendBubble): a second tap
        // during the send window would cancel a leave that already delivered
        // and emit a duplicate .leave bubble (post-push audit).
        guard !isSending else { return }
        sendTask?.cancel()
        sendTask = Task { @MainActor in
            isSending = true
            sendStatusMessage = "Leaving this meetup..."
            presentUI(for: presentationStyle)

            let remainingParticipants = participantListWithoutMe()

            let fallbackCoordinate = LocationCache.loadSelf()?.coordinate
                ?? remainingParticipants.first?.coordinate
                ?? MapGeometry.defaultCenter
            let state = TweenState(
                text: "I'm out",
                latitude: fallbackCoordinate.latitude,
                longitude: fallbackCoordinate.longitude,
                senderName: UserProfile.displayName,
                senderID: self.localParticipantID(),
                kind: .participant,
                messageType: .leave,
                participants: remainingParticipants,
                revision: self.nextOutgoingRevision()
            )
            logger.debug("Encoding I'm out reply participants=\(remainingParticipants.count, privacy: .public)")
            let didSend = await sendBubbleNow(for: state)
            // A direct-send rejection stages the bubble in the input field —
            // the user hasn't actually left until they tap send on it (they
            // can still delete it). Committing the leave here anyway made
            // THIS device believe it left while no peer ever learned, the
            // classic "lingering person on everyone's map" split-brain. The
            // staged commit now waits for didStartSending.
            if didSend, sendStatusMessage != Self.stagedDeliveryStatus {
                commitDeliveredLeave(remaining: remainingParticipants)
            }
            isSending = false
            if didSend {
                // Preserve the insert-fallback's "tap send to deliver" hint —
                // only clear the status when it's still our in-progress copy.
                if sendStatusMessage == "Leaving this meetup..." { sendStatusMessage = nil }
            } else if !Task.isCancelled {
                sendStatusMessage = "Couldn't send the Tween message. Try again."
            }
            presentUI(for: presentationStyle)
        }
    }

    /// The local-state half of a leave. Runs only once the leave bubble was
    /// actually delivered (direct send) or actually sent by the user (staged
    /// bubble → `didStartSending`). Clears EVERYTHING meetup-scoped: after
    /// "I'm out" no roster residue, ranked spots, drafts, or stale map state
    /// may survive on this device (device feedback).
    func commitDeliveredLeave(remaining: [Participant]) {
        // Keep the REMAINING roster, not [] — the meetup is still live for
        // everyone else (group-session semantics), and wiping it here made
        // the next rejoin broadcast a roster of just [me], erasing the group
        // on every device that tapped it. "Am I in" is answered by
        // membership, not roster emptiness.
        currentParticipants = remaining
        // The scoped snapshot (recordCanonicalSnapshot .leave) keeps the
        // rejoin roster; the un-TTL'd GLOBAL mirrors must not — a roster
        // parked there outlived the snapshot's 24 h window and resurrected
        // the departed peer in the host app (audit at 18c182a).
        LocationCache.clearParticipants()
        LocationCache.setPeerActive(false)
        LocationCache.deactivateSelf()
        LocationCache.clearAgreedMeetup()
        // Tombstone: peers who never tap this leave bubble will keep
        // sending rosters that include this user — decode filters
        // those entries until an explicit rejoin. Any staged-send marker
        // from an earlier abandoned bubble is moot once a real leave lands.
        if let conversationKey {
            ConversationMeetupStore.setLocalUserLeft(true, key: conversationKey)
            ConversationMeetupStore.setPendingStagedSend(nil, key: conversationKey)
        }
        // An in-flight ranking would repopulate the spot list right after
        // this reset; a surviving draft (in-memory or the App-Group
        // hand-off blob) re-offered a pending message after leaving.
        rankingTask?.cancel()
        isRanking = false
        rankedSpots = []
        draft = nil
        OutgoingDraftStore.clear()
        recentlySentSpotName = nil
        // Drop the decoded meetup too — CompactView's thumbnail and
        // ExpandedView's peer pins render from `received.participants`,
        // so leaving it set kept everyone on the leaver's map. The next
        // activation stays clean via the snapshot-restore gate (the
        // .leave canonical snapshot wiped the store).
        received = nil
    }

    /// Proposes a specific ranked spot to the group. The participants list is
    /// carried forward verbatim so the recipient knows everyone's in.
    func sendChosenSpot(_ spot: RankedSpot) {
        guard let item = spot.item else { return }
        let coordinate = item.placemark.coordinate
        // Fresh-only (audit W4): a cache older than the 5-min window must
        // not ride into the outgoing roster as if it were current — the
        // roster/currentParticipants fallback below carries the last
        // coordinate peers actually saw instead.
        let mySelf = LocationCache.isActive ? LocationCache.loadSelf()?.coordinate : nil
        // Make sure my own entry is in the participants list before proposing.
        let participants: [Participant]
        if let mySelf {
            participants = nextParticipantList(myCoord: mySelf, conversation: activeConversation)
        } else {
            participants = currentParticipants
        }

        let state = TweenState(
            text: item.name ?? "Spot",
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            senderName: UserProfile.displayName,
            senderID: localParticipantID(),
            kind: .place,
            senderCoordinate: mySelf,
            messageType: .propose,
            participants: participants,
            revision: nextOutgoingRevision()
        )
        sendBubble(state: state) { [weak self] in
            guard let self else { return }
            // Commit the roster only on delivery; the conversation-scoped
            // write is covered by recordCanonicalSnapshot (.propose).
            self.currentParticipants = participants
            LocationCache.saveParticipantSnapshot(participants, localContext: localParticipantContext())
        }
    }

    /// Agrees to a previously proposed place. Carries the participants forward
    /// and appends this user's identity to the agreement list; the receiver decides if
    /// that's enough for full consensus via `state.isFullyAgreed`.
    func sendAgreedPlace(_ proposed: TweenState) {
        let myName = Self.localParticipantName()
        let myId = localParticipantID()
        guard !proposed.isProposer(participantID: myId, name: myName),
              !proposed.hasAgreed(participantID: myId, name: myName) else {
            received = effectiveReceived(decoded: proposed)
            presentUI(for: presentationStyle)
            return
        }
        // Re-entrancy guard: without it the Agree button stayed enabled for
        // the whole location-fix + send window, and a second tap past the
        // point of no return emitted a second .agree bubble (audit).
        guard !isSending else { return }
        sendTask?.cancel()
        sendTask = Task { @MainActor in
            isSending = true
            sendStatusMessage = "Sending your agreement..."
            presentUI(for: presentationStyle)
            // Same fresh-fix-first policy as handleImIn: never agree with a
            // stale coord that might land you in a worst-case route the
            // ranker would have rejected.
            let senderCoordinate: CLLocationCoordinate2D?
            if let manual = LocationCache.loadSelf(), manual.isManual == true, LocationCache.isActive {
                // Respect a declared "I'll be at…" location — agree with THAT,
                // never overwrite it with a live GPS fix (which would broadcast
                // your CURRENT spot and strip the declaration). Sibling of the
                // handleImIn guard; missing it here was a post-push audit find.
                senderCoordinate = manual.coordinate
            } else if let fresh = await acquireLocation() {
                // Cache the fix but keep the prior active flag — activation
                // (which the host app reads as "you're in") is committed only
                // once the agree bubble is actually delivered
                // (commitDeliveredAgree keys it off senderCoordinate).
                LocationCache.save(fresh, isActive: LocationCache.isActive)
                senderCoordinate = fresh
            } else if LocationCache.isActive, let cached = LocationCache.loadSelf()?.coordinate {
                senderCoordinate = cached
            } else {
                // No fresh fix and the cache is stale/inactive: omit the
                // sender coordinate (bubble drops slat/slon) rather than
                // broadcasting a stale location as current (audit W4).
                senderCoordinate = nil
            }

            // Build the forward participants list. The proposed bubble's
            // participants are authoritative; refresh my entry's coord.
            var participants = proposed.participants.isEmpty
                ? self.currentParticipants
                : proposed.participants
            if let myCoord = senderCoordinate {
                let myId = self.localParticipantID()
                let legacyID = self.legacyLocalParticipantID()
                participants = participants.filter { !$0.matches(id: myId, name: myName) && $0.id != legacyID }
                let needsRide = proposed.participants.first(where: { $0.matches(id: myId, name: myName) })?.needsRide
                    ?? self.currentParticipants.first(where: { $0.matches(id: myId, name: myName) })?.needsRide
                    ?? LocationCache.loadParticipants().first(where: { $0.matches(id: myId, name: myName) })?.needsRide
                    ?? false
                participants.append(Participant(id: myId, name: myName, coordinate: myCoord, needsRide: needsRide))
            }

            var agreed = proposed.agreedNames
            // Case-insensitive replace-then-append: "hassan" and "Hassan" are
            // the same person, so a case-variant duplicate would inflate the
            // "X of Y agreed" copy — and appending keeps me as
            // `agreedNames.last`, which captions read as the most recent
            // agreer. agreedIDs drive real consensus; this is display-only.
            agreed.removeAll { $0.caseInsensitiveCompare(myName) == .orderedSame }
            agreed.append(myName)
            // Legacy proposals (no senderID) stay in the NAME namespace end to
            // end. The old fallback stamped the AGREER's id as proposer, which
            // excluded the wrong person from consensus (T7) — and appending a
            // UUID to agreedIDs while the roster ids are names made
            // `isFullyAgreed` compare across namespaces and never fire (T6).
            var agreedIDs: [String]
            if proposed.senderID != nil {
                agreedIDs = proposed.agreedIDs
                if !agreedIDs.contains(myId) { agreedIDs.append(myId) }
            } else {
                agreedIDs = []
            }

            // Preserve the original proposer so consensus is calculated
            // against every other participant, not the most recent agreer.
            let state = TweenState(
                text: proposed.text,
                latitude: proposed.latitude,
                longitude: proposed.longitude,
                senderName: proposed.senderName ?? UserProfile.displayName,
                senderID: proposed.senderID,
                kind: .place,
                senderCoordinate: senderCoordinate,
                action: .agree,
                messageType: .agree,
                participants: participants,
                agreedNames: agreed,
                agreedIDs: agreedIDs,
                revision: self.nextOutgoingRevision()
            )
            logger.debug("Agreeing to place \(proposed.text, privacy: .public) agreed=\(agreed.count, privacy: .public)")
            // Don't dismiss after an agree send — instead, lock in the local
            // view as the terminal MEETUP SET so the agreer immediately sees
            // "It's a plan!" with map-app direction choices, rather than being
            // bounced back to the iMessage thread. The receiver gets the same
            // view via didReceive → presentUI.
            let didSend = await sendBubbleNow(for: state)
            // Direct-send rejection stages the bubble — the user hasn't
            // actually agreed until they tap send on it (they can delete it
            // instead). Same deferral as handleImOut: the staged commit
            // waits for didStartSending / the decode backstop, so a deleted
            // staged agree can't leave this device rendering a MEETUP SET
            // no peer ever saw (post-push audit).
            if didSend, sendStatusMessage != Self.stagedDeliveryStatus {
                commitDeliveredAgree(state)
            }
            isSending = false
            if didSend {
                // Preserve the insert-fallback's "tap send to deliver" hint —
                // only clear the status when it's still our in-progress copy.
                if sendStatusMessage == "Sending your agreement..." { sendStatusMessage = nil }
            } else if !Task.isCancelled {
                sendStatusMessage = "Couldn't send the Tween message. Try again."
            }
            self.presentUI(for: self.presentationStyle)
        }
    }

    /// The local-state half of an agree. Runs only once the agree bubble was
    /// actually delivered (direct send) or actually sent by the user (staged
    /// bubble → `commitStagedSendIfNeeded`).
    func commitDeliveredAgree(_ state: TweenState) {
        // A usable coordinate rode along — agreeing means being in. When no
        // fresh or cached fix existed the bubble omitted slat/slon and this
        // device's opt-in state stays untouched, exactly as before.
        if state.senderCoordinate != nil {
            LocationCache.setActive(true)
        }
        currentParticipants = state.participants
        // Agreeing means being in — clear the leave tombstone (and any
        // stale staged-send marker) BEFORE the roster write: LocationCache's
        // global-mirror writes are dammed while the tombstone is set
        // (audit at 69a3886).
        if let conversationKey {
            ConversationMeetupStore.setLocalUserLeft(false, key: conversationKey)
            ConversationMeetupStore.setPendingStagedSend(nil, key: conversationKey)
        }
        LocationCache.saveParticipantSnapshot(state.participants, localContext: localParticipantContext())
        // Persist the agreement so re-opening the extension (after iOS
        // dispose, or after the user collapses + re-taps) re-renders
        // MEETUP SET instead of the propose's Agree/Change buttons.
        // Gated on real delivery: a rejected or still-staged send must not
        // render MEETUP SET when no bubble ever reached the chat.
        if state.isFullyAgreed {
            LocationCache.saveAgreedMeetup(state)
            if let conversationKey {
                ConversationMeetupStore.saveAgreed(state, key: conversationKey)
            }
        } else if let conversationKey {
            ConversationMeetupStore.saveProposed(state, key: conversationKey)
        }
        received = effectiveReceived(decoded: state)
    }

    /// Counter-proposes a different spot, resetting agreement to zero. The
    /// proposer becomes the local user and the agreedNames list starts empty.
    func sendCounter(_ spot: RankedSpot) {
        guard let item = spot.item else { return }
        let coordinate = item.placemark.coordinate
        // Fresh-only (audit W4): a cache older than the 5-min window must
        // not ride into the outgoing roster as if it were current — the
        // roster/currentParticipants fallback below carries the last
        // coordinate peers actually saw instead.
        let mySelf = LocationCache.isActive ? LocationCache.loadSelf()?.coordinate : nil
        let participants: [Participant]
        if let mySelf {
            participants = nextParticipantList(myCoord: mySelf, conversation: activeConversation)
        } else {
            participants = currentParticipants
        }

        let state = TweenState(
            text: item.name ?? "Spot",
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            senderName: UserProfile.displayName,
            senderID: localParticipantID(),
            kind: .place,
            senderCoordinate: mySelf,
            messageType: .counter,
            participants: participants,
            agreedNames: [],
            revision: nextOutgoingRevision()
        )
        sendBubble(state: state) { [weak self] in
            guard let self else { return }
            self.currentParticipants = participants
            LocationCache.saveParticipantSnapshot(participants, localContext: localParticipantContext())
            // A counter restarts negotiation — any prior agreement is
            // invalidated, so the persisted terminal cache must be cleared
            // too. Cleared only on delivery: a failed counter must not erase
            // this device's MEETUP SET while peers still hold theirs. The
            // conversation-scoped saveProposed (which also drops the scoped
            // agreed state for counters) is covered by recordCanonicalSnapshot.
            LocationCache.clearAgreedMeetup()
        }
    }

    /// Confirms a host-app hand-off: composes the bubble for the staged draft,
    /// clears it so it isn't offered again, and re-renders.
    func sendDraft() {
        guard let draft else { return }
        // Fresh-only (audit W4): a cache older than the 5-min window must
        // not ride into the outgoing roster as if it were current — the
        // roster/currentParticipants fallback below carries the last
        // coordinate peers actually saw instead.
        let mySelf = LocationCache.isActive ? LocationCache.loadSelf()?.coordinate : nil
        let participants: [Participant]
        if let mySelf {
            participants = nextParticipantList(myCoord: mySelf, conversation: activeConversation)
        } else {
            participants = currentParticipants
        }

        let state = TweenState(
            text: draft.spotName,
            latitude: draft.latitude,
            longitude: draft.longitude,
            senderName: UserProfile.displayName,
            senderID: localParticipantID(),
            kind: .place,
            senderCoordinate: mySelf,
            messageType: .propose,
            participants: participants,
            revision: nextOutgoingRevision()
        )
        sendBubble(state: state) { [weak self] in
            guard let self else { return }
            self.currentParticipants = participants
            LocationCache.saveParticipantSnapshot(participants, localContext: localParticipantContext())
            // The staged hand-off is consumed only once the bubble is
            // delivered — a failed send keeps the draft offered instead of
            // losing it. Store-side draft clearing is covered by
            // recordCanonicalSnapshot (.propose → clearDraft); sendBubble's
            // own didSend block clears self.draft for place sends.
            OutgoingDraftStore.clear()
        }
    }

    /// `onDelivered` runs only after the bubble was actually delivered (or
    /// staged via the insert fallback) — callers park their local-state
    /// commits there so a failed send never leaves this device claiming
    /// something peers didn't receive. Nil default keeps legacy callers as-is.
    func sendBubble(state: TweenState, onDelivered: (() -> Void)? = nil) {
        // Re-entrancy guard (same as sendAgreedPlace): a second tap during the
        // render + `conversation.send` window would cancel the first task AFTER
        // it already delivered, then send a duplicate bubble. Covers the propose
        // / counter / draft sends that funnel through here.
        guard !isSending else { return }
        sendTask?.cancel()
        sendTask = Task { @MainActor in
            isSending = true
            sendStatusMessage = sendingMessage(for: state)
            presentUI(for: presentationStyle)

            let didSend = await sendBubbleNow(for: state)
            isSending = false
            if didSend {
                onDelivered?()
                if state.kind == .place {
                    recentlySentSpotName = state.text
                    received = nil
                    draft = nil
                    rankedSpots = []
                }
                // Preserve the insert-fallback's "tap send to deliver" hint —
                // only claim "sent" when the status is still our in-progress copy.
                if sendStatusMessage == sendingMessage(for: state) {
                    sendStatusMessage = sentMessage(for: state)
                }
            } else if !Task.isCancelled {
                sendStatusMessage = "Couldn't send the Tween message. Try again."
            }
            presentUI(for: presentationStyle)
        }
    }

    func sendingMessage(for state: TweenState) -> String {
        switch state.messageType {
        case .propose, .counter:
            return "Sending \(state.text)..."
        case .agree:
            return "Sending your agreement..."
        case .leave:
            return "Leaving this meetup..."
        case .invite:
            return "Sharing your location..."
        }
    }

    func sentMessage(for state: TweenState) -> String {
        switch state.messageType {
        case .propose, .counter:
            return "Sent \(state.text) to the chat"
        case .agree:
            return "Agreement sent"
        case .leave:
            return "You're out"
        case .invite:
            return "You're in"
        }
    }

}
