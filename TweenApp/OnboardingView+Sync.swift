import SwiftUI
import MapKit
import CoreLocation
import MessageUI
import Messages
import UIKit
import Combine
import os

// App Group refresh + peer polling (split from OnboardingView.swift — structure plan R2).
extension OnboardingView {
    // MARK: - Peer polling

    var appGroupDidChangePublisher: NotificationCenter.Publisher {
        NotificationCenter.default.publisher(
            for: UserDefaults.didChangeNotification,
            object: UserDefaults(suiteName: LocationCache.appGroup)
        )
    }

    @MainActor
    func pollPeer() async {
        // Fallback cadence only — MeetupSync Darwin notifications deliver
        // changes immediately; this loop just catches anything a missed
        // notification would leave behind (e.g. a writer predating the posts).
        while !Task.isCancelled {
            _ = pollRefreshFromAppGroup()
            try? await Task.sleep(for: .seconds(2))
        }
    }

    /// Poll-safe wrapper around `refreshFromAppGroup()` — suppresses any
    /// programmatic write to `selectedSheetDetent` for the duration of the
    /// refresh so the 300 ms App Group poll cannot fight the user's sheet
    /// drag. Docs: `docs/ui-research.md` §1 (self-jump).
    ///
    /// User-initiated refresh paths (`.onAppear`, scene resume,
    /// `handleIncomingURL`) still call `refreshFromAppGroup()` directly so the
    /// "agreed just landed" detent nudge fires as intended when a user opens
    /// or returns to the app.
    @MainActor
    @discardableResult
    func pollRefreshFromAppGroup() -> Bool {
        suppressPollDetentWrites = true
        defer { suppressPollDetentWrites = false }
        return refreshFromAppGroup()
    }

    /// Whether a poll/refresh that observes a local leave should reset an open
    /// search ranking. TRUE only when the refresh is tearing down live peer
    /// state THIS tick — never on the subsequent polls where the tombstone still
    /// reads "left" but the peer is already gone, or a fresh solo/manual A→B
    /// search started after leaving would be wiped on every 2 s tick.
    static func shouldResetRankingOnLeave(localLeft: Bool, hasLivePeerState: Bool) -> Bool {
        localLeft && hasLivePeerState
    }

    @MainActor
    @discardableResult
    func refreshFromAppGroup() -> Bool {
        // Group-aware path: the extension writes the full participants roster
        // whenever it receives or sends a bubble. If present, keep the first
        // remote participant as `peerCoordinate` for legacy call sites and draw
        // the rest as group participants.
        let myName = UserProfile.displayName ?? UserName.fallback
        // Same freshness rule as the extension: a snapshot past its TTL is
        // history, not a live meetup, so the poll must not keep painting it.
        let scopedSnapshot = ConversationMeetupStore.lastActiveConversationKey
            .flatMap { ConversationMeetupStore.load(key: $0) }
            .flatMap { Date().timeIntervalSince($0.updatedAt) <= ConversationMeetupStore.snapshotTTL ? $0 : nil }
        let roster = scopedSnapshot?.participants ?? LocationCache.loadParticipants()
        let localContext = LocalParticipantContext(id: TweenIdentity.stableID, name: myName)
        let remotes = roster.filter { !$0.matches(localContext) }
        let localParticipant = roster.first { $0.matches(localContext) }

        // Peers stop existing for THIS device once the local user LEFT the
        // conversation's meetup. The roster deliberately keeps the remaining
        // group in the STORE after "I'm out" (a rejoin must restore everyone
        // — D4), but projecting those coordinates into live state kept the
        // leaver's search results ranking against the departed friend and
        // showing "distance between you" chips (device feedback: leaving
        // must fully reset, not just hide the pin). Keyed on the
        // per-conversation leave TOMBSTONE — not membership/opt-in — so a
        // pinged friend who joined FIRST still previews (reply banner,
        // framed pins) before this user taps I'm in, and conversation A's
        // opt-in can't resurrect conversation B's departed roster
        // (post-push audit at 42fdc68).
        // Provenance-matched: the tombstone only judges a roster that came
        // from ITS conversation's snapshot. When the scoped snapshot is
        // absent (TTL-expired, or a drawer-peek re-pointed the key at a
        // thread this user left long ago) the roster above fell back to the
        // GLOBAL participants blob — possibly a different, live meetup that
        // key's tombstone has no authority over (audit at 2b894b0).
        let localLeft = scopedSnapshot != nil
            && (ConversationMeetupStore.lastActiveConversationKey
                .map { ConversationMeetupStore.localUserLeft(key: $0) } ?? false)
        let newPeer: CLLocationCoordinate2D?
        let newPeerName: String
        let newPeerNeedsRide: Bool
        let newExtras: [Participant]
        if let firstRemote = remotes.first, !localLeft {
            newPeer = firstRemote.coordinate
            // Sanitise for display (audit F2): an unnamed sender's legacy "You"
            // (or an empty name) reads as "Friend", never "You". Identity keeps
            // riding on the stable id, so only the shown label changes.
            newPeerName = UserName.peerDisplayName(firstRemote.name)
            newPeerNeedsRide = firstRemote.needsRide
            newExtras = remotes.dropFirst().map { p in
                Participant(id: p.id, name: UserName.peerDisplayName(p.name),
                            coordinate: p.coordinate, needsRide: p.needsRide)
            }
        } else if !localLeft {
            newPeer = LocationCache.isPeerActive ? LocationCache.loadPeer()?.coordinate : nil
            newPeerName = "Friend"
            newPeerNeedsRide = false
            newExtras = []
        } else {
            newPeer = nil
            newPeerName = "Friend"
            newPeerNeedsRide = false
            newExtras = []
        }
        // An extension-side leave reaches this device as the tombstone +
        // deactivated flags — it must reset an open results list exactly
        // like the app-side leave (commitLeaveLocally) does, or the stale
        // "You X min | Sam Y min" chips survive until the next search.
        //
        // But ONLY on the tick that actually tears down live peer state — NOT
        // on every poll. The leave tombstone lingers for the conversation, so
        // an unconditional clear here wiped a fresh solo/manual A→B search the
        // user started AFTER leaving: it ranked, then the next 2 s poll nuked
        // rankedSpots and the list fell back to raw distance (device feedback:
        // "search works, then it refreshes and loses all logic"). A solo ranking
        // (self + an added place, no peer) has no departed-peer chips to clear.
        // `peerCoordinate`/`additionalParticipants` still hold their pre-update
        // values here (reconciled below), so they detect the teardown tick.
        let hasLivePeerState = peerCoordinate != nil || !additionalParticipants.isEmpty
        if Self.shouldResetRankingOnLeave(localLeft: localLeft, hasLivePeerState: hasLivePeerState) {
            if !rankedSpots.isEmpty {
                rankedSpots = []
            }
            // An open place sheet captured its ranked ETAs at present time —
            // scored against the meetup just left. Solo-opened sheets carry
            // ranked == nil (post-leave searches can't rank), so they stay.
            if case .spot(let selection) = activeSheet, selection.ranked != nil {
                activeSheet = nil
            }
        }

        var didChange = false
        if currentParticipants != roster {
            currentParticipants = roster
            didChange = true
        }
        if peerDisplayName != newPeerName {
            peerDisplayName = newPeerName
            didChange = true
        }
        if peerNeedsRide != newPeerNeedsRide {
            peerNeedsRide = newPeerNeedsRide
            didChange = true
        }
        if localNeedsRide != (localParticipant?.needsRide ?? false) {
            localNeedsRide = localParticipant?.needsRide ?? false
            didChange = true
        }
        if !same(peerCoordinate, newPeer) {
            peerCoordinate = newPeer
            didChange = true
            if let newPeer {
                logger.debug("Main app loaded peer coordinate lat=\(newPeer.latitude, privacy: .public) lon=\(newPeer.longitude, privacy: .public)")
            } else {
                logger.debug("Main app cleared inactive peer coordinate")
            }
        }
        if additionalParticipants != newExtras {
            additionalParticipants = newExtras
            didChange = true
            if !newExtras.isEmpty {
                logger.debug("Main app loaded \(newExtras.count, privacy: .public) additional participants")
            }
        }

        let cachedSelfBlob = LocationCache.loadSelf()
        let cachedSelf = cachedSelfBlob?.coordinate
        if !same(savedCoordinate, cachedSelf) {
            savedCoordinate = cachedSelf
            // This coordinate came from the cache, not a live fix — clear the
            // in-memory freshness stamp so `freshSelfCoordinateForSend` judges
            // it by the cache's own timestamp rather than treating it as fresh
            // as of now. (Otherwise a refresh could overwrite a live fix with
            // an older cache value while the stamp still read "recent".)
            savedCoordinateAt = nil
            didChange = true
        }
        // Restore the declared-location provenance from the cache so a relaunch
        // or a poll tick keeps the GPS-clobber guard + "You'll be at…" labels
        // consistent with what was saved (the place NAME isn't persisted — the
        // cache holds coords + prefs only — so the label may generalise). Only
        // an ACTIVE declaration counts — after a leave it's deactivated and must
        // stop lingering as a manual self (post-push audit).
        let cachedIsManual = cachedSelfBlob?.isManual == true && cachedSelfBlob?.isActive == true
        if selfIsManual != cachedIsManual {
            selfIsManual = cachedIsManual
            if !cachedIsManual { selfManualLabel = nil }
        }
        // Presence tracks the opt-in flag, NOT coordinate freshness — the old
        // `isActive` read silently flipped "I'm in" back off five minutes
        // after the last fix while peers still counted this user in.
        let active = LocationCache.isOptedIn
        if isUserIn != active {
            isUserIn = active
            didChange = true
        }

        let cachedAgreedMeetup = scopedSnapshot?.agreedState ?? LocationCache.loadAgreedMeetup()
        if agreedMeetup != cachedAgreedMeetup {
            agreedMeetup = cachedAgreedMeetup
            // Poll-driven deselect: latch the detent restore off (read the
            // defer-scoped flag NOW, while it's still true — the onChange
            // that consumes the latch runs after the defer resets it).
            if suppressPollDetentWrites, selectedResult != nil {
                suppressNextDeselectDetentRestore = true
            }
            selectedResult = nil
            didChange = true
            if cachedAgreedMeetup != nil {
                // Self-jump gate: skip the tab AND detent writes when this
                // refresh was driven by the 300 ms poll (or another background
                // App Group signal) — a background tick must not yank controls
                // the user may be interacting with. User-initiated refresh
                // paths keep the peek nudge. See docs/ui-research.md §1.
                if !suppressPollDetentWrites {
                    selectedSheetDetent = .height(Tokens.Layout.sheetPeekHeight)
                }
            }
        }

        // Mirror the in-flight proposal (propose / counter / partial agree)
        // so opening the app mid-negotiation shows it. Renders ALONGSIDE a
        // set meetup when both exist — see visiblePendingProposal.
        let cachedProposal = Self.visiblePendingProposal(
            proposed: scopedSnapshot?.proposedState,
            agreed: cachedAgreedMeetup)
        if pendingProposal != cachedProposal {
            pendingProposal = cachedProposal
            didChange = true
            // Same peek nudge as the agreed path: the proposal card floats
            // over the map just above the collapsed sheet, so a half-open
            // sheet would hide it. Gated like every background-driven write
            // so a poll/notification tick can't yank controls mid-drag.
            if cachedProposal != nil, !suppressPollDetentWrites {
                selectedSheetDetent = .height(Tokens.Layout.sheetPeekHeight)
            }
        }

        lastReplyAt = PingLog.lastIncomingReplyAt
        lastGenericInviteAt = PingLog.lastGenericInviteAt
        // Camera writes obey the same self-jump gate as detent writes: a
        // background poll/notification tick detecting a change (e.g. a peer
        // coordinate update) must not yank the map out from under a user
        // who has panned or zoomed. User-initiated refresh paths (.onAppear,
        // scene resume, handleIncomingURL) still reframe as intended.
        if didChange, !suppressPollDetentWrites {
            reframe()
        }
        return didChange
    }

}
