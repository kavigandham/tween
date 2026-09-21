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
                // Stamped with the fix's MEASUREMENT time, not receipt time:
                // a one-shot can hand back CoreLocation's cached fix, and
                // re-dating it to Date() would launder its age into the
                // 5-minute freshness window both processes trust
                // (audit 2026-08-05).
                LocationCache.save(fresh, at: locationProvider.lastFixAt ?? Date(),
                                   isActive: LocationCache.isActive)
                coordinate = fresh
            } else if LocationCache.isActive, let cached = LocationCache.loadSelf()?.coordinate {
                coordinate = cached
                logger.debug("Used cached self coord (fresh fix unavailable)")
            } else {
                isSending = false
                // A send cancelled by willResignActive lands here too — without
                // this guard it stamped the permission-blaming error, and the
                // message survived reopening the conversation (readiness audit
                // 2026-08-06). Its three sibling paths already guard.
                if !Task.isCancelled {
                    sendStatusMessage = "Location unavailable. Check permission and try again."
                    presentUI(for: presentationStyle)
                }
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
        // The THIRD leave arm. Leaving from inside iMessage is the same user
        // intent as the host's "I'm out", but only the host arms ended the
        // schedule — so a Pro user who left here still saw the host's plan
        // banner advertising it (audit 2026-08-06). Modes survive; endMeetup
        // reads the raw blob, so this is entitlement-safe from the extension
        // too. cancel() is also called here — removing a pending request needs
        // no authorization, and the host-side collection only runs when the
        // user next FOREGROUNDS the app, which leaving from inside iMessage
        // makes unlikely before the nudge fires (audit 2026-08-06). If an
        // extension's notification center can't reach the host's requests
        // this is a harmless no-op and LeaveByRefresher still collects it.
        MeetupPlanStore.endMeetup()
        LeaveByReminder.cancel()
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
        // The board and the "on the way" strip go with it. The STORED board
        // deliberately survives (the meetup is still live for everyone else,
        // and a rejoin restores it — same reasoning as the roster above);
        // this device just stops rendering a vote it walked out of.
        poll = .empty
        enRouteMarks = []
    }

    // MARK: - The vote board
    //
    // `sendChosenSpot` / `sendCounter` / `sendAgreedPlace` used to live here:
    // one live proposal, agreed to or replaced. They're gone. A place now goes
    // on a BOARD (`MeetupPoll`) that everyone votes on, so "I'd rather go
    // somewhere else" adds a second option instead of overwriting the first —
    // see MeetupPoll's type comment for why the old shape produced an
    // agreement to the place someone was disagreeing with.

    /// Puts a place on the board under the local user's name and votes for it.
    /// Replaces this user's previous pick, if they had one.
    func sendPick(_ spot: RankedSpot) {
        guard let item = spot.item else { return }
        sendPick(name: item.name ?? "Spot", coordinate: item.placemark.coordinate)
    }

    func sendPick(name: String, coordinate: CLLocationCoordinate2D) {
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

        let option = PollOption(name: name, coordinate: coordinate,
                                proposerID: localParticipantID())
        var board = poll.normalized(participants: participants,
                                    departed: departedForActiveConversation())
        board.pick(option)

        // A pick NEVER settles the meetup, however the arithmetic falls — see
        // MeetupPoll.settledOption. It's a new contender by definition.
        let state = TweenState(
            text: option.name,
            latitude: option.latitude,
            longitude: option.longitude,
            senderName: UserProfile.displayName,
            senderID: localParticipantID(),
            kind: .place,
            senderCoordinate: mySelf,
            messageType: .pick,
            participants: participants,
            revision: nextOutgoingRevision(),
            poll: board
        )
        sendBubble(state: state) { [weak self] in
            guard let self else { return }
            self.currentParticipants = participants
            self.mergePoll(board, from: .localDevice)
            LocationCache.saveParticipantSnapshot(participants, localContext: localParticipantContext())
            // A new place on the board reopens the question, so a terminal
            // state cached from a previous round must go. Cleared only on
            // delivery: a failed pick must not erase this device's meetup
            // while peers still hold theirs.
            LocationCache.clearAgreedMeetup()
            // A pick is also how a host-app hand-off is delivered (sendDraft),
            // so the staged draft is consumed here — on delivery, never before.
            OutgoingDraftStore.clear()
        }
    }

    /// Casts (or changes) this user's vote. When the board comes out
    /// unanimous, the same tap sends the DECISION instead — the vote that
    /// finishes it is the decision, so nobody has to confirm twice.
    func sendVote(for option: PollOption) {
        sendBoardUpdate(applying: { board, myID in board.vote(myID, for: option.id) },
                        focus: option,
                        progressCopy: "Sending your vote...")
    }

    /// Ends the vote on `option` explicitly — the escape hatch for a
    /// plurality ("3 of 5 want Hey Tea, let's just go") and for a tie nobody
    /// is breaking. Named after what it picks, never a bare "confirm".
    func lockIn(_ option: PollOption) {
        sendBoardUpdate(applying: { board, myID in
                            board.vote(myID, for: option.id)
                            board.lockIn(option.id)
                        },
                        focus: option,
                        progressCopy: "Locking in \(option.name)...")
    }

    /// One send path for every board mutation: apply locally, work out
    /// whether the result is terminal, compose, deliver, and only then commit.
    /// Sharing it is what keeps "a vote that settles it" and "an explicit
    /// lock-in" from drifting into two different terminal states.
    private func sendBoardUpdate(applying mutate: @escaping (inout MeetupPoll, String) -> Void,
                                 focus: PollOption,
                                 progressCopy: String) {
        // Re-entrancy guard, same as every other sender: a second tap during
        // the location-fix + render window would emit a duplicate bubble.
        guard !isSending else { return }
        sendTask?.cancel()
        sendTask = Task { @MainActor in
            isSending = true
            sendStatusMessage = progressCopy
            presentUI(for: presentationStyle)

            // Same fresh-fix-first policy as handleImIn: voting counts you as
            // in, so the coordinate riding along must be current, and a
            // declared "I'll be at…" must never be overwritten by a live fix.
            let senderCoordinate: CLLocationCoordinate2D?
            if let manual = LocationCache.loadSelf(), manual.isManual == true, LocationCache.isActive {
                senderCoordinate = manual.coordinate
            } else if let fresh = await acquireLocation() {
                LocationCache.save(fresh, at: locationProvider.lastFixAt ?? Date(),
                                   isActive: LocationCache.isActive)
                senderCoordinate = fresh
            } else if LocationCache.isActive, let cached = LocationCache.loadSelf()?.coordinate {
                senderCoordinate = cached
            } else {
                senderCoordinate = nil
            }

            let myID = self.localParticipantID()
            let participants: [Participant]
            if let senderCoordinate {
                participants = self.nextParticipantList(myCoord: senderCoordinate,
                                                        conversation: self.activeConversation)
            } else {
                participants = self.currentParticipants
            }

            var board = self.poll.normalized(participants: participants,
                                             departed: self.departedForActiveConversation())
            // The user tapped a row they could SEE, so the option has to be on
            // the board before we mutate it — otherwise voting for an option
            // this device only knew from the open bubble is a silent no-op.
            // But NEVER re-add a place whose chooser has left: `normalized`
            // just dropped it, and putting it back here is what turned a
            // stale render into a `.decided` broadcast that pinned everyone
            // else to it (post-push audit 2026-09-21).
            if !self.departedForActiveConversation().contains(focus.proposerID) {
                board.ensure(focus)
            }
            mutate(&board, myID)
            let settled = board.settledOption(participants: participants)
            // The spot the bubble is ABOUT: the winner once it's settled,
            // otherwise the option just voted for. Legacy builds read this as
            // the agreed place, which is true in both cases.
            let subject = settled ?? focus
            // Back-compat: a `.decided` must read as a FULL agreement to a
            // build that predates the poll, or a 1.0.3 user sees "0 of 2
            // agreed" under a meetup that's set. `isFullyAgreed` excludes the
            // SENDER and requires everyone else in `agreedIDs` — so listing
            // everyone but me satisfies it without lying about who sent this.
            //
            // The bubble used to claim the winning option's PROPOSER as its
            // sender to get the same effect. Three receive-side mechanisms key
            // off `senderID`: the revision floor's tie-break owner,
            // `RosterMerge.clearDeparted` (so a vote for a departed person's
            // pick resurrected them), and referral attribution — plus the
            // caption read "Hassan voted for Hey Tea" when Belal voted
            // (audit 2026-09-19).
            let agreedIDs = settled == nil ? [] : participants.map(\.id).filter { $0 != myID }
            let agreedNames = settled == nil ? [] : participants.filter { $0.id != myID }.map(\.name)

            let state = TweenState(
                text: subject.name,
                latitude: subject.latitude,
                longitude: subject.longitude,
                senderName: UserProfile.displayName,
                senderID: myID,
                kind: .place,
                senderCoordinate: senderCoordinate,
                messageType: settled == nil ? .vote : .decided,
                participants: participants,
                agreedNames: agreedNames,
                agreedIDs: agreedIDs,
                revision: self.nextOutgoingRevision(),
                poll: board
            )
            logger.debug("Sending board update type=\(state.messageType.rawValue, privacy: .public) options=\(board.options.count, privacy: .public)")

            let didSend = await sendBubbleNow(for: state)
            // A staged bubble hasn't happened yet — the user can still delete
            // it instead of sending. Same deferral as the leave path: the
            // commit waits for didStartSending / the decode backstop.
            if didSend, sendStatusMessage != Self.stagedDeliveryStatus {
                commitDeliveredBoard(state)
            }
            isSending = false
            if didSend {
                if sendStatusMessage == progressCopy {
                    sendStatusMessage = settled == nil ? nil : "It's a plan"
                }
            } else if !Task.isCancelled {
                sendStatusMessage = "Couldn't send the Tween message. Try again."
            }
            self.presentUI(for: self.presentationStyle)
        }
    }

    /// The local-state half of a vote or a decision. Runs only once the bubble
    /// was actually delivered (direct send) or actually sent by the user
    /// (staged bubble → `commitStagedSendIfNeeded`).
    func commitDeliveredBoard(_ state: TweenState) {
        // A usable coordinate rode along — voting means being in. When no
        // fresh or cached fix existed the bubble omitted slat/slon and this
        // device's opt-in state stays untouched.
        if state.senderCoordinate != nil {
            LocationCache.setActive(true)
        }
        currentParticipants = state.participants
        // Voting means being in — clear the leave tombstone (and any stale
        // staged-send marker) BEFORE the roster write: LocationCache's
        // global-mirror writes are dammed while the tombstone is set.
        if let conversationKey {
            ConversationMeetupStore.setLocalUserLeft(false, key: conversationKey)
            ConversationMeetupStore.setPendingStagedSend(nil, key: conversationKey)
        }
        LocationCache.saveParticipantSnapshot(state.participants, localContext: localParticipantContext())
        mergePoll(state.poll, from: .localDevice)
        if state.isDecided {
            LocationCache.saveAgreedMeetup(state)
            if let conversationKey {
                ConversationMeetupStore.saveAgreed(state, key: conversationKey)
            }
        } else if let conversationKey {
            ConversationMeetupStore.saveProposed(state, key: conversationKey)
        }
        received = effectiveReceived(decoded: state)
    }

    // MARK: - Leaving now

    /// "I'm heading over" — announces departure WITH this user's live ETA to
    /// the settled place, which is the whole point: the message a group
    /// actually needs at that moment is "12 min away", not "leaving now".
    ///
    /// The ETA is resolved at send time from the user's CURRENT location, and
    /// falls back to a straight-line estimate when MapKit can't route (or
    /// times out) rather than sending a bare, uninformative announcement.
    func sendLeavingNow() {
        guard !isSending else { return }
        guard let destination = enRouteDestination else { return }
        sendTask?.cancel()
        sendTask = Task { @MainActor in
            isSending = true
            sendStatusMessage = "Getting your ETA..."
            presentUI(for: presentationStyle)

            let origin: CLLocationCoordinate2D?
            if let fresh = await acquireLocation() {
                LocationCache.save(fresh, at: locationProvider.lastFixAt ?? Date(),
                                   isActive: LocationCache.isActive)
                origin = fresh
            } else {
                origin = LocationCache.loadSelf()?.coordinate
            }

            var seconds: Int?
            if let origin {
                let mode = MeetupPlanStore.current.mode(for: TweenIdentity.stableID)
                let travel = await FairnessRanker.travelTime(
                    from: origin, to: destination.coordinate, mode: mode)
                seconds = Int(travel.rounded())
            }
            guard !Task.isCancelled else { return }

            let participants = origin.map {
                self.nextParticipantList(myCoord: $0, conversation: self.activeConversation)
            } ?? self.currentParticipants
            // Legacy builds read `.enroute` as a full agreement, which it is —
            // you only leave for a place the group settled on. Excludes ME
            // because `isFullyAgreed` excludes the sender (see sendBoardUpdate).
            let myID = self.localParticipantID()
            let agreedIDs = participants.map(\.id).filter { $0 != myID }
            let agreedNames = participants.filter { $0.id != myID }.map(\.name)

            let state = TweenState(
                text: destination.name,
                latitude: destination.latitude,
                longitude: destination.longitude,
                senderName: UserProfile.displayName,
                senderID: self.localParticipantID(),
                kind: .place,
                senderCoordinate: origin,
                messageType: .enroute,
                participants: participants,
                agreedNames: agreedNames,
                agreedIDs: agreedIDs,
                revision: self.nextOutgoingRevision(),
                poll: self.poll.normalized(participants: participants,
                                           departed: self.departedForActiveConversation()),
                etaSeconds: seconds
            )
            let didSend = await sendBubbleNow(for: state)
            isSending = false
            if didSend {
                self.currentParticipants = participants
                LocationCache.saveParticipantSnapshot(participants, localContext: localParticipantContext())
                self.noteEnRoute(participantID: self.localParticipantID(), seconds: seconds)
                if sendStatusMessage == "Getting your ETA..." {
                    sendStatusMessage = seconds.map {
                        "On your way — about \(max(Int((Double($0) / 60).rounded()), 1)) min"
                    } ?? "On your way"
                }
            } else if !Task.isCancelled {
                sendStatusMessage = "Couldn't send the Tween message. Try again."
            }
            self.presentUI(for: self.presentationStyle)
        }
    }

    /// Where "Leaving now" would send you: the settled option, or the decided
    /// place carried by whatever bubble is on screen (a thread that settled on
    /// a pre-poll build still gets the button).
    var enRouteDestination: PollOption? {
        if let settled = settledOption { return settled }
        guard let received, received.isDecided, received.kind == .place else { return nil }
        return PollOption(name: received.text,
                          latitude: received.latitude,
                          longitude: received.longitude,
                          proposerID: received.senderID ?? received.senderName ?? "")
    }

    /// Confirms a host-app hand-off: composes the bubble for the staged draft,
    /// clears it so it isn't offered again, and re-renders.
    func sendDraft() {
        guard let draft else { return }
        // A hand-off from the host app is a PICK like any other — it used to
        // go out as a `.propose`, which meant "search in the app, send" reset
        // the negotiation instead of joining it (this is the path the reported
        // bug arrived through most often). The draft is consumed in the pick's
        // own delivery block below.
        let spotName = draft.spotName
        sendPick(name: spotName,
                 coordinate: CLLocationCoordinate2D(latitude: draft.latitude,
                                                    longitude: draft.longitude))
        // The staged hand-off is consumed only once the bubble is delivered —
        // a failed send keeps the draft offered instead of losing it.
        // sendBubble's own didSend block clears `self.draft` for place sends,
        // and recordCanonicalSnapshot clears the stored one.
        _ = spotName
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
            // A STAGED bubble sits in the input field and the user can still
            // delete it instead of sending. Committing here anyway consumed
            // the host-app draft and cleared this device's settled meetup for
            // a pick no peer ever received — contradicting sendDraft's own
            // promise that a failed send keeps the draft. The commit waits for
            // didStartSending / the decode backstop, like every other sender.
            let staged = sendStatusMessage == Self.stagedDeliveryStatus
            if didSend, !staged {
                onDelivered?()
                if state.kind == .place {
                    recentlySentSpotName = state.text
                    // Keep the state we just sent when it carries a board:
                    // clearing it dropped the roster the vote is scored
                    // against (and the map's pins) the instant you picked.
                    // A board-less place send keeps the old reset.
                    received = state.poll.options.isEmpty ? nil : state
                    draft = nil
                    rankedSpots = []
                }
            }
            if didSend {
                // Preserve the insert-fallback's "tap send to deliver" hint —
                // only claim "sent" when the status is still our in-progress
                // copy. Gating this whole arm on `!staged` (as the first cut of
                // the staged-pick fix did) dropped a STAGED send into the
                // failure arm below, so the user got a red "Couldn't send"
                // banner over a bubble sitting in the input field ready to go
                // (audit 2026-09-19).
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
        case .propose, .counter, .pick:
            return "Sending \(state.text)..."
        case .agree, .vote:
            return "Sending your vote..."
        case .decided:
            return "Locking in \(state.text)..."
        case .enroute:
            return "Telling everyone you're on the way..."
        case .leave:
            return "Leaving this meetup..."
        case .invite:
            return "Sharing your location..."
        }
    }

    func sentMessage(for state: TweenState) -> String {
        switch state.messageType {
        case .propose, .counter, .pick:
            return "\(state.text) is on the board"
        case .agree, .vote:
            return "Vote sent"
        case .decided:
            return "It's a plan"
        case .enroute:
            return "On your way"
        case .leave:
            return "You're out"
        case .invite:
            return "You're in"
        }
    }

}
