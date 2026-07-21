import SwiftUI
import MapKit
import CoreLocation
import MessageUI
import Messages
import UIKit
import Combine
import os

// Presence actions, profile name, DEBUG demo seeds (split from OnboardingView.swift — structure plan R2).
extension OnboardingView {
    // MARK: - Actions

    func imIn() {
        ensureNamed {
            // A live GPS join clears any declared "I'll be at…" so the fresh fix
            // takes over.
            selfIsManual = false
            selfManualLabel = nil
            awaitingImIn = true
            provider.requestOnce()
        }
    }

    /// Joins the meetup with a DECLARED future location (a place you're heading
    /// to) instead of live GPS — "I'll be at…". The declared coordinate is
    /// freshness-exempt (LocationCache.isManual) so it travels in the bubble and
    /// isn't overwritten by a background GPS fix.
    func setManualSelf(_ point: Participant) {
        ensureNamed {
            // Cancel any in-flight GPS request so its late .got can't overwrite
            // this declaration (the .got guard keys on !awaitingImIn).
            awaitingImIn = false
            pendingLocationAction = nil
            let coord = point.coordinate
            selfIsManual = true
            selfManualLabel = point.name
            savedCoordinate = coord
            savedCoordinateAt = Date()
            isUserIn = true
            LocationCache.save(coord, isActive: true, isManual: true)
            saveLocalParticipant(coord)   // this is what travels to the group
            withAnimation(Tokens.Motion.spring) {
                position = Self.cameraPosition(for: [coord])
            }
            showToast("You'll be at \(point.name)")
        }
    }

    // MARK: - Profile name

    /// Persists the Friends-tab name field (clearing it when blank).
    func saveProfileName() {
        let trimmed = profileName.trimmingCharacters(in: .whitespacesAndNewlines)
        UserProfile.displayName = trimmed.isEmpty ? nil : trimmed
    }

    /// Runs `action` immediately when a display name is set; otherwise prompts
    /// for one first and runs `action` after the user saves it.
    func ensureNamed(_ action: @escaping () -> Void) {
        if let name = UserProfile.displayName, !name.isEmpty {
            action()
        } else {
            nameDraft = profileName
            pendingNameAction = action
            showNamePrompt = true
        }
    }

    func saveName() {
        let trimmed = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            UserProfile.displayName = trimmed
            profileName = trimmed
        }
        pendingNameAction?()
        pendingNameAction = nil
    }

    /// Auto-requests location on launch so the map opens on the user's real
    /// location instead of a generic default. Prompts on first launch
    /// (`requestOnce` handles the authorization branch internally); silent on
    /// subsequent launches once granted. Skipped when we already have a fresh
    /// shared coordinate, so an active "I'm in" session isn't disturbed.
    /// -DEMO_SPOT_SHEET: runs a real MKLocalSearch on launch and opens the
    /// full place sheet for the first hit — screenshot/UI-test hook for the
    /// rich native place-detail layout, which needs a REAL place identifier
    /// (the coordinate-only demo pin can't exercise it).
    func openDemoSpotSheetIfRequested() async {
        #if DEBUG
        // -DEMO_ROUTE_AB seeded one added point at init; also seed a self
        // location (in the cache, so the poll keeps it) and run a real search so
        // the solo A→B ranking (fair spots between the two) renders.
        if CommandLine.arguments.contains("-DEMO_ROUTE_AB") {
            let sanJose = CLLocationCoordinate2D(latitude: 37.3382, longitude: -121.8863)
            LocationCache.save(sanJose, isActive: true)
            savedCoordinate = sanJose
            await runSearch(trimmed: "coffee", reframeMap: true)
            // Combine with -DEMO_SPOT_SHEET to exercise the exact user path:
            // a real, identifier-backed MapKit place opened from a ranked map
            // pin, with Tween's participant times above Apple's rich detail.
            if CommandLine.arguments.contains("-DEMO_SPOT_SHEET"),
               let item = displayedItems.first {
                activeSheet = .spot(SpotSelection(item: item, ranked: rankedMatch(for: item)))
            }
            return
        }
        // -DEMO_SETTINGS: opens the Settings sheet (maps-app preference) for
        // screenshots.
        if CommandLine.arguments.contains("-DEMO_SETTINGS") {
            activeSheet = .settings
            return
        }
        // -DEMO_CATEGORY_STUDY: seeds two points then taps the Study chip —
        // screenshot hook proving category chips run the POI-category engine
        // (libraries/cafés BETWEEN the points, not a dead text search).
        if CommandLine.arguments.contains("-DEMO_CATEGORY_STUDY") {
            let sanJose = CLLocationCoordinate2D(latitude: 37.3382, longitude: -121.8863)
            LocationCache.save(sanJose, isActive: true)
            savedCoordinate = sanJose
            manualParticipants = [Participant.manual(label: "Adams Center",
                coordinate: CLLocationCoordinate2D(latitude: 37.28, longitude: -121.95))]
            selectCategory(.study)
            return
        }
        // -DEMO_SOLO_AFTER_LEAVE: regression for the "ranking wiped on refresh"
        // device bug. Seeds a LEFT-meetup tombstone in the active conversation,
        // then a solo A→B search (self + one added place). The leave tombstone
        // makes refreshFromAppGroup's localLeft branch clear rankedSpots on every
        // poll tick, so the fresh solo ranking flickers away ~2 s after it lands.
        if CommandLine.arguments.contains("-DEMO_SOLO_AFTER_LEAVE") {
            let key = ConversationMeetupStore.conversationKey(localID: "me", remotes: ["friend"])
            ConversationMeetupStore.lastActiveConversationKey = key
            ConversationMeetupStore.save(MeetupSnapshot(
                conversationKey: key,
                participants: [Participant(id: "friend", name: "Friend",
                    coordinate: CLLocationCoordinate2D(latitude: 39.05, longitude: -77.5))]))
            ConversationMeetupStore.setLocalUserLeft(true, key: key)
            let sanJose = CLLocationCoordinate2D(latitude: 37.3382, longitude: -121.8863)
            LocationCache.save(sanJose, isActive: true)
            savedCoordinate = sanJose
            manualParticipants = [Participant.manual(label: "Adams Center",
                coordinate: CLLocationCoordinate2D(latitude: 37.28, longitude: -121.95))]
            await runSearch(trimmed: "coffee", reframeMap: true)
            return
        }
        // -DEMO_SPOT_CARD seeded a selection at init, which never fires
        // onChange — present its sheet here (fallback layout, no identifier).
        if CommandLine.arguments.contains("-DEMO_SPOT_CARD"), let item = selectedResult {
            // -DEMO_SPOT_GROUP seeds a 4-person ranking so the place sheet shows
            // the per-person time chips + drive-balance track (audit F1) — the
            // host used to cap this at two people. Screenshot hook only.
            let ranked = CommandLine.arguments.contains("-DEMO_SPOT_GROUP")
                ? RankedSpot(item: item, etas: [
                    ParticipantETA(id: "you", name: "You", eta: 480, fromRoute: true),
                    ParticipantETA(id: "kavi", name: "Kavi", eta: 720, fromRoute: true),
                    ParticipantETA(id: "maya", name: "Maya", eta: 600, fromRoute: true),
                    ParticipantETA(id: "sam", name: "Sam", eta: 960, fromRoute: true)
                  ], confidence: 1.0)
                : nil
            activeSheet = .spot(SpotSelection(item: item, ranked: ranked))
            return
        }
        guard CommandLine.arguments.contains("-DEMO_SPOT_SHEET") else { return }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = "coffee"
        request.region = MKCoordinateRegion(
            center: savedCoordinate ?? Self.defaultCenter,
            span: MKCoordinateSpan(latitudeDelta: 0.3, longitudeDelta: 0.3))
        guard let item = try? await MKLocalSearch(request: request).start().mapItems.first else { return }
        activeSheet = .spot(SpotSelection(item: item, ranked: nil))
        #endif
    }

    func requestInitialLocation() {
        guard !(savedCoordinate != nil && LocationCache.isActive) else { return }
        provider.requestOnce()
    }

    func leave() {
        let myName = UserProfile.displayName ?? UserName.fallback
        let localContext = LocalParticipantContext(id: TweenIdentity.stableID, name: myName)
        let roster = scopedFirstRoster()
        let fallbackCoordinate = LocationCache.loadSelf()?.coordinate
            ?? roster.first(where: { $0.matches(localContext) })?.coordinate
            ?? Self.defaultCenter
        let remainingParticipants = roster.filter { !$0.matches(localContext) }
        if remainingParticipants.isEmpty && !hasSharedPlanToCancel {
            commitLeaveLocally(remaining: [], revision: nil)
            showToast("You're out")
            return
        }
        // Nothing commits here. Leaving takes effect only once the leave
        // bubble is actually sent (commitLeaveLocally, via onSent) — the same
        // didSend gating the extension uses. Committing up front left this
        // device "out" with no leave bubble in the chat when the composer was
        // cancelled: a split-brain the peers could never repair.
        presentLeaveMessage(participants: remainingParticipants, fallbackCoordinate: fallbackCoordinate)
    }

    var hasSharedPlanToCancel: Bool {
        if pendingProposal != nil || agreedMeetup != nil { return true }
        guard let key = ConversationMeetupStore.lastActiveConversationKey,
              let snapshot = ConversationMeetupStore.load(key: key),
              Date().timeIntervalSince(snapshot.updatedAt) <= ConversationMeetupStore.snapshotTTL
        else { return false }
        return snapshot.proposedState != nil || snapshot.agreedState != nil
    }

    func presentLeaveMessage(participants: [Participant],
                                     fallbackCoordinate: CLLocationCoordinate2D) {
        let revision = nextOutgoingRevisionForActiveConversation()
        let state = TweenState(
            text: "I'm out",
            latitude: fallbackCoordinate.latitude,
            longitude: fallbackCoordinate.longitude,
            senderName: UserProfile.displayName,
            senderID: TweenIdentity.stableID,
            kind: .participant,
            messageType: .leave,
            participants: participants,
            revision: revision
        )

        guard MFMessageComposeViewController.canSendText() else {
            UIPasteboard.general.string = "I'm out of this meetup."
            showToast("Messages unavailable - copied an I'm out reply")
            return
        }

        Task { @MainActor in
            guard let message = await composeTweenMessage(
                for: state, totalSeats: max(participants.count + 1, 2)) else { return }
            activeSheet = .message(PendingMessage(
                recipients: [],
                body: "I'm out of this meetup.",
                message: message,
                onSent: {
                    commitLeaveLocally(remaining: participants, revision: revision)
                },
                onCancelled: {
                    // Leaving IS a message in a serverless app — without the
                    // bubble, nobody can ever learn you left. Say so.
                    showToast("You're still in — your I'm out wasn't sent")
                }))
        }
    }

    /// The local effects of leaving, applied only after the leave bubble was
    /// actually sent. Keeps the REMAINING roster rather than wiping to [] —
    /// the meetup is still live for everyone else (group-session semantics),
    /// and an empty roster made the next rejoin broadcast just [me], erasing
    /// the group on every device that tapped it. "Out" is expressed by
    /// membership + the leave tombstone, not by roster emptiness.
    func commitLeaveLocally(remaining: [Participant], revision: Int?) {
        withAnimation(Tokens.Motion.spring) { isUserIn = false }
        localNeedsRide = false
        noteOutgoingRevision(revision)
        if let key = ConversationMeetupStore.lastActiveConversationKey {
            // The rejoin roster (D4) lives in the SCOPED snapshot only.
            ConversationMeetupStore.saveParticipants(remaining, key: key)
            ConversationMeetupStore.clearProposalState(key: key)
            // Tombstone: stale peer rosters must not re-add this user as "in".
            ConversationMeetupStore.setLocalUserLeft(true, key: key)
        }
        // The GLOBAL mirrors never keep a departed conversation's roster:
        // they have no TTL, so a roster parked there outlived the scoped
        // snapshot's 24 h window and resurrected the departed peer in
        // ranking/banners once the provenance gate lost its snapshot (audit
        // at 18c182a). Rejoin reads the scoped snapshot (saveLocalParticipant),
        // so clearing here costs nothing.
        LocationCache.clearParticipants()
        LocationCache.setPeerActive(false)
        LocationCache.deactivateSelf()
        LocationCache.clearAgreedMeetup()
        agreedMeetup = nil
        selectedResult = nil
        // Explicit, not just via the refresh below — the recompute path
        // depends on lastActiveConversationKey being set, and a stale
        // proposal card surviving a leave is exactly the "leftover state
        // after I'm out" the device feedback flagged.
        pendingProposal = nil
        // Fairness rankings were computed against the meetup you just left —
        // an open results list must drop its "You X min | Sam Y min" chips
        // immediately, not keep scoring spots against the departed friend
        // (device feedback: leaving must fully reset).
        rankedSpots = []
        // A staged "Send to chat" hand-off is a pending message; leaving must
        // not let the extension re-adopt it within its 15-min handoff window.
        OutgoingDraftStore.clear()
        _ = refreshFromAppGroup()
    }

    /// Mints the next outgoing payload revision for the most recently active
    /// conversation, mirroring the extension. Deliberately NOT recorded at
    /// mint time — `noteOutgoingRevision` runs in the composer's onSent so a
    /// cancelled send never burns a revision (burned revisions made the
    /// peer's genuinely-new bubbles decode as stale and vanish).
    func nextOutgoingRevisionForActiveConversation() -> Int? {
        guard let key = ConversationMeetupStore.lastActiveConversationKey else { return nil }
        return ConversationMeetupStore.lastRevision(key: key) + 1
    }

    func noteOutgoingRevision(_ revision: Int?) {
        guard let revision, let key = ConversationMeetupStore.lastActiveConversationKey else { return }
        ConversationMeetupStore.noteRevision(revision, sender: TweenIdentity.stableID, key: key)
    }

    /// Builds the Tween-styled `MSMessage` for a state: renders the bubble
    /// image, applies the caption layout, and attaches the payload URL. The
    /// single composer behind every host-app send — this block used to be
    /// copy-pasted at five call sites. Returns nil when the payload can't be
    /// encoded: never ship a payload-less bubble, the recipient's extension
    /// would decode nothing from the tapped message.
    func composeTweenMessage(for state: TweenState, totalSeats: Int) async -> MSMessage? {
        // Departure gossip, mirroring the extension's deliverBubble: outgoing
        // payloads carry this device's tombstones so any later tap anywhere
        // in the group propagates removals.
        var outgoing = state
        if let key = ConversationMeetupStore.lastActiveConversationKey {
            outgoing.departed = RosterMerge.gossipKeys(
                departed: ConversationMeetupStore.departedParticipants(key: key),
                roster: state.participants)
        }
        let image = await BubbleImageRenderer.makeImage(
            state: state,
            participants: state.participants,
            localName: UserProfile.displayName ?? UserName.fallback)
        let layout = MSMessageTemplateLayout()
        layout.image = image
        BubbleCaption.apply(to: layout, state: state, totalSeats: totalSeats)
        // https, never tween:// — MSMessage.url is resolved by recipients
        // without the app (and macOS Messages) through the browser fallback,
        // and the hard constraint mandates https/file. The extension already
        // sends https; the decoder accepts both.
        guard let bubbleURL = outgoing.encodedURL() else { return nil }
        let message = MSMessage()
        message.url = bubbleURL
        message.layout = layout
        return message
    }

    /// The conversation-scoped roster when FRESH, else the legacy global
    /// blob. The scoped snapshot is authoritative — it alone survives a
    /// leave, carrying the D4 rejoin roster (the global mirrors are dammed
    /// while the tombstone is set) — but a snapshot past its TTL is history,
    /// not a live meetup, and must not be rebroadcast as current (audit at
    /// 69a3886). One helper so every outgoing-roster read agrees.
    func scopedFirstRoster() -> [Participant] {
        if let key = ConversationMeetupStore.lastActiveConversationKey,
           let snapshot = ConversationMeetupStore.load(key: key),
           Date().timeIntervalSince(snapshot.updatedAt) <= ConversationMeetupStore.snapshotTTL {
            return snapshot.participants
        }
        return LocationCache.loadParticipants()
    }

    func saveLocalParticipant(_ coordinate: CLLocationCoordinate2D) {
        let myName = UserProfile.displayName ?? UserName.fallback
        let localContext = LocalParticipantContext(id: TweenIdentity.stableID, name: myName)
        let participants = scopedFirstRoster().filter { !$0.matches(localContext) } + [
            Participant(id: TweenIdentity.stableID, name: myName, coordinate: coordinate, needsRide: localNeedsRide)
        ]
        if let key = ConversationMeetupStore.lastActiveConversationKey {
            ConversationMeetupStore.saveParticipants(participants, key: key)
            // Opting in clears the leave tombstone — BEFORE the global
            // write below, which LocationCache dams while it's set
            // (audit at 69a3886).
            ConversationMeetupStore.setLocalUserLeft(false, key: key)
        }
        LocationCache.saveParticipantSnapshot(participants, localContext: localContext)
        currentParticipants = participants
    }

    func setNeedsRide(_ needsRide: Bool) {
        // Requires being IN, not just having a cached coordinate: the ride
        // toggle used to auto-rejoin (and clear the leave tombstone) for a
        // user who had explicitly said "I'm out" — a silent resurrection.
        guard isUserIn else {
            showToast("Tap I'm in first so friends know where to pick you up")
            return
        }
        // Fresh-only: a ride update broadcasts a pickup point, so a stale
        // coordinate must not ride along (audit W4). Park + request a fresh
        // fix and resume, rather than sending an old location.
        guard let coordinate = freshSelfCoordinateForSend else {
            pendingLocationAction = { setNeedsRide(needsRide) }
            provider.requestOnce()
            showToast("Getting your location — updating your ride status right after")
            return
        }
        localNeedsRide = needsRide
        saveLocalParticipant(coordinate)
        _ = refreshFromAppGroup()
        presentRideStatusMessage(needsRide: needsRide, coordinate: coordinate)
        showToast(needsRide ? "Ride request ready to send" : "Ride update ready to send")
    }

    func presentRideStatusMessage(needsRide: Bool, coordinate: CLLocationCoordinate2D) {
        let myName = UserProfile.displayName ?? UserName.fallback
        let participants = scopedFirstRoster()
        let revision = nextOutgoingRevisionForActiveConversation()
        let state = TweenState(
            text: needsRide ? "I need a ride" : "I can meet there",
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            senderName: UserProfile.displayName,
            senderID: TweenIdentity.stableID,
            kind: .participant,
            messageType: .invite,
            participants: participants,
            revision: revision
        )

        guard MFMessageComposeViewController.canSendText() else {
            UIPasteboard.general.string = needsRide
                ? "\(myName) needs a ride for this Tween meetup."
                : "\(myName) can meet there for this Tween meetup."
            showToast("Messages unavailable - copied the ride update")
            return
        }

        Task { @MainActor in
            guard let message = await composeTweenMessage(
                for: state, totalSeats: max(participants.count, 2)) else { return }
            activeSheet = .message(PendingMessage(
                recipients: [],
                body: needsRide ? "\(myName) needs a ride." : "\(myName) can meet there.",
                message: message,
                onSent: {
                    noteOutgoingRevision(revision)
                    showToast(needsRide ? "Ride request sent" : "Ride update sent")
                },
                onCancelled: {
                    showToast(needsRide ? "Ride request not sent" : "Ride update not sent")
                }))
        }
    }

}
