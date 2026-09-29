import SwiftUI
import MapKit
import CoreLocation
import MessageUI
import UIKit

// Arrival Sync in the HOST APP.
//
// The extension is where a departure is initiated — that is where the group
// settles on a place and where "I Left" lives. The host app's job is the other
// three quarters of the feature:
//
//   * RECEIVE. A departure bubble opened through the app (every plain-text
//     `tween://` body lands here) must arm a reminder exactly as the extension
//     would, or the coordination depends on which surface the user happened to
//     tap.
//   * ASK. The extension never requests notification permission — a permission
//     alert must not appear over somebody's conversation — so the host is the
//     only place that can, and it asks at the one contextually appropriate
//     moment: a meetup is actively coordinating and the user just opened the
//     app.
//   * REPAIR. `reconcileArrivalSync` collects a sync the extension stored but
//     could not arm, the same way `LeaveByRefresher` collects an orphaned
//     leave-by reminder. Foreground-only: re-checking in the background would
//     need Always location, which Tween does not ask for (constraint 4).
//   * SHOW. With notifications denied the feature still works — the leave time
//     is on screen.
extension OnboardingView {

    /// A FRESH read of the live sync, straight from the App Group.
    ///
    /// Event handlers only — never a view body. This decodes JSON, and
    /// `ArrivalSyncStore.load` also REAPS an expired sync, which writes to the
    /// suite and posts `MeetupSync`; doing that during view evaluation is a
    /// side effect in a place SwiftUI may re-run at will. The rendered value
    /// is `arrivalSync`, refreshed on the App Group tick like every other
    /// mirror here (the same rule the extension states at
    /// `MessagesViewController.presentUI`).
    var activeArrivalSync: ArrivalSyncState? {
        guard let key = ConversationMeetupStore.lastActiveConversationKey else { return nil }
        return ArrivalSyncStore.load(key: key)
    }

    /// The local user's own slice of the MIRRORED sync — no store read, so it
    /// is safe to call from a body as often as SwiftUI likes.
    var myArrivalSyncEntry: ArrivalParticipantState? {
        arrivalSync?.participant(TweenIdentity.stableID)
    }

    // MARK: - Receiving

    /// Applies a departure bubble opened through the app.
    ///
    /// Deliberately the SAME service call the extension makes, with the same
    /// idempotence: `eventID` is content-derived, so both surfaces processing
    /// one bubble arm one reminder rather than two.
    func receiveArrivalSync(_ state: TweenState) {
        guard state.messageType == .enroute, state.arrivalTarget != nil,
              let key = ConversationMeetupStore.lastActiveConversationKey else { return }
        let participants = ConversationMeetupStore.load(key: key)?.participants ?? []
        let departed = ConversationMeetupStore.departedParticipants(key: key)
        let origin = LocationCache.loadSelf()?.coordinate ?? savedCoordinate
        Task { @MainActor in
            // Ask FIRST, and only here. A user who has never been asked would
            // otherwise have the event applied, no reminder armed, and no idea
            // why — and this is the moment the permission is obviously for.
            _ = await LeaveByReminder.requestAuthorization()
            let result = await ArrivalSyncService.receive(
                event: state,
                meetingID: key,
                localID: TweenIdentity.stableID,
                localName: UserProfile.displayName ?? UserName.fallback,
                localOrigin: origin,
                participants: participants,
                departed: departed)
            announceArrivalSync(result, departingName: state.senderName.map(UserName.peerDisplayName))
        }
    }

    /// Host foreground repair pass. Cheap when there is nothing to do: one
    /// App Group read, and a notification-centre round trip only when a sync
    /// actually exists (the gating lesson from `LeaveByRefresher`, which used
    /// to pay that round trip on every foreground for users who never planned).
    func reconcileArrivalSync() {
        guard let key = ConversationMeetupStore.lastActiveConversationKey,
              ArrivalSyncStore.stored(key: key) != nil else { return }
        let origin = LocationCache.loadSelf()?.coordinate ?? savedCoordinate
        Task { @MainActor in
            let result = await ArrivalSyncService.reconcile(
                meetingID: key,
                localID: TweenIdentity.stableID,
                localName: UserProfile.displayName ?? UserName.fallback,
                localOrigin: origin)
            // Silent on repair: the user did not just do anything, so a toast
            // here would fire on every foreground of a live meetup. Only the
            // "you should already be going" case is worth interrupting for.
            if case .leaveNow = result {
                announceArrivalSync(result,
                                    departingName: ArrivalSyncStore.load(key: key)?.initiatedByName)
            }
        }
    }

    /// One place that turns a reception result into user-facing copy, so the
    /// toast and the notification can never describe the same state two ways.
    func announceArrivalSync(_ result: ArrivalSyncService.ReceptionResult,
                             departingName: String?) {
        let who = departingName ?? activeArrivalSync?.initiatedByName ?? "Your friend"
        switch result {
        case .leaveNow:
            showToast("\(who) left — you should leave now to arrive together.")
        case .armed(let departure):
            showToast("\(who) is on the way — leave at \(ArrivalSyncNotifier.timeFormatter.string(from: departure)).")
        case .duplicate, .notApplicable, .stale:
            break
        }
    }

    // MARK: - Notification tap

    /// Lands the user on the meetup an Arrival Sync notification is about.
    ///
    /// No new navigation model: the agreed meetup is already restored into
    /// `agreedMeetup` from the App Group, so this frames the map on the
    /// destination and lifts the sheet to its peek height — the same thing a
    /// cold open with a live negotiation does.
    func focusArrivalSyncMeetup() {
        _ = refreshFromAppGroup()
        guard let sync = activeArrivalSync else {
            // The sync expired, or the meetup ended while the notification sat
            // on the lock screen. Say so rather than silently doing nothing.
            showToast("That meetup has finished.")
            return
        }
        activeSheet = nil
        withAnimation(Tokens.Motion.gentle) {
            position = Self.placeCameraPosition(for: sync.destinationCoordinate)
            selectedSheetDetent = .height(Tokens.Layout.sheetPeekHeight)
        }
        // From `sync`, not the mirror: `refreshFromAppGroup` above has just
        // repointed the mirror, but reading @State back inside the same call
        // is exactly the kind of ordering assumption that rots.
        if let mine = sync.participant(TweenIdentity.stableID),
           mine.departureStatus != .departed,
           let travel = mine.estimatedTravelTime {
            if ArrivalSyncTiming.shouldLeaveNow(targetArrival: sync.targetArrivalTime,
                                                travelTime: travel) {
                showToast("Leave now to reach \(sync.destinationName) with \(sync.initiatedByName).")
            } else if let departure = mine.recommendedDepartureTime {
                showToast("Leave at \(ArrivalSyncNotifier.timeFormatter.string(from: departure)) to reach \(sync.destinationName) together.")
            }
        }
    }

    // MARK: - Cleanup

    /// Ends the sync for the active conversation — the user left the meetup, or
    /// cancelled it. Paired with every existing `LeaveByReminder.cancel()` site
    /// for the same reason those exist: a "time to go" for a meetup you walked
    /// out of is not a stale notification, it is a wrong instruction.
    func cancelActiveArrivalSync() {
        guard let key = ConversationMeetupStore.lastActiveConversationKey else { return }
        ArrivalSyncService.cancel(meetingID: key)
        // Drop the mirror in the same turn as the store clear. The App Group
        // tick would catch up within ~300 ms, but this runs on "I'm out" —
        // the banner for a meetup the user just walked out of should not
        // survive a single frame, let alone a poll interval.
        arrivalSync = nil
    }

    /// Invalidates a sync aimed at a place the group is no longer meeting at.
    /// Every departure time in it was subtracted from an arrival measured to
    /// somewhere else, so only a fresh I Left can re-establish it.
    ///
    /// Driven from `refreshFromAppGroup`'s agreed-meetup TRANSITION, not from
    /// individual deep-link branches: the destination can change through a
    /// received bubble, a local pick, or the extension writing the App Group,
    /// and wiring one of those three is how this ended up never running at
    /// all. The meetup is passed in rather than read from `agreedMeetup`
    /// because the caller knows the new value before @State carries it.
    ///
    /// - Returns: true when a sync was torn down, so the caller can drop its
    ///   mirror in the same tick instead of rendering a dead banner.
    @discardableResult
    func invalidateArrivalSyncIfDestinationChanged(against meetup: TweenState?) -> Bool {
        guard let key = ConversationMeetupStore.lastActiveConversationKey else { return false }
        let agreed = meetup.flatMap { state -> (String, CLLocationCoordinate2D)? in
            guard state.isDecided, state.kind == .place, !state.text.isEmpty else { return nil }
            return (state.text, state.coordinate)
        }
        return ArrivalSyncService.invalidateIfDestinationChanged(
            meetingID: key,
            destinationName: agreed?.0,
            destination: agreed?.1)
    }

    // MARK: - Reciprocating

    /// "I Left", from the host app — the other half of the coordination.
    ///
    /// The departure notice tells the reader to tell everyone else when THEY
    /// leave, and a notification tap lands here, so this has to exist or that
    /// prompt is a dead end. It is deliberately the SIMPLE half of the
    /// feature: V1 keeps the first departure as the synchronisation target
    /// (the spec's "do not over-engineer dynamic group ETA optimization"), so
    /// this announces this user's own ETA, carries the EXISTING target so a
    /// peer who never opened the first bubble still learns it, marks this user
    /// departed, and retires their own reminder. It re-aims nobody.
    ///
    /// Not Pro-gated: responding to a sync somebody else started is the
    /// receiving side, and Pro gates initiating only.
    func sendArrivalSyncDeparture() {
        guard let key = ConversationMeetupStore.lastActiveConversationKey,
              let sync = ArrivalSyncStore.load(key: key) else { return }
        guard MFMessageComposeViewController.canSendText() else {
            UIPasteboard.general.string = "Leaving now for \(sync.destinationName)"
            showToast("Messages unavailable — copied a reply for you")
            return
        }
        guard autoJoinForOutgoingMessage() else {
            // The user already said yes; resume once the fix lands rather than
            // dropping the departure (the same parking pattern as sendToChat).
            pendingLocationAction = { sendArrivalSyncDeparture() }
            provider.requestOnce()
            showToast("Getting your location — telling them right after")
            return
        }
        let myID = TweenIdentity.stableID
        let myName = UserProfile.displayName ?? UserName.fallback
        let mySelf = freshSelfCoordinateForSend
        let revision = nextOutgoingRevisionForActiveConversation()

        var participants = (ConversationMeetupStore.load(key: key)?.participants ?? [])
            .filter { !$0.matches(LocalParticipantContext(id: myID, name: myName)) }
        if let mySelf {
            participants.append(Participant(id: myID, name: myName,
                                            coordinate: mySelf, needsRide: localNeedsRide))
        }

        Task { @MainActor in
            // Fresh, like every other departure: the leg measured when the
            // place was chosen was for a different moment.
            var seconds: Int?
            if let mySelf {
                let travel = await FairnessRanker.travelTime(
                    from: mySelf,
                    to: sync.destinationCoordinate,
                    mode: MeetupPlanStore.current.mode(for: myID))
                seconds = Int(travel.rounded())
            }
            let state = TweenState(
                text: sync.destinationName,
                latitude: sync.destinationLatitude,
                longitude: sync.destinationLongitude,
                senderName: UserProfile.displayName,
                senderID: myID,
                kind: .place,
                senderCoordinate: mySelf,
                action: .agree,
                messageType: .enroute,
                participants: participants,
                // An `.enroute` is a full agreement by definition — you only
                // leave for a place the group settled on. Excludes ME, like
                // every other consensus payload here.
                agreedNames: participants.filter { $0.id != myID }.map(\.name),
                agreedIDs: participants.map(\.id).filter { $0 != myID },
                revision: revision,
                poll: activeConversationBoard().normalized(
                    participants: participants, departed: activeConversationDeparted()),
                etaSeconds: seconds,
                // The ORIGINAL target, not a new one: this departure joins the
                // existing sync rather than restarting it, and carrying it
                // teaches the target to anyone who never opened the first
                // bubble.
                arrivalTarget: sync.targetArrivalTime)
            guard let message = await composeTweenMessage(
                for: state, totalSeats: state.participants.count) else { return }
            activeSheet = .message(PendingMessage(
                recipients: [],
                body: Self.spotBody(prefix: "Leaving now —",
                                    name: sync.destinationName,
                                    coordinate: sync.destinationCoordinate),
                message: message,
                onSent: {
                    noteOutgoingRevision(revision)
                    // Committed in `onSent` ONLY. A cancelled composer must
                    // not leave this device believing it told anyone, and
                    // must not retire a reminder that is still correct.
                    _ = ArrivalSyncService.noteLocalDeparture(meetingID: key, localID: myID)
                    showToast("Told them you're on your way.")
                }))
        }
    }

    // MARK: - Banner

    /// "Hassan is on the way · leave at 6:10 PM" — the in-app answer, which is
    /// what makes the feature work with notifications denied.
    ///
    /// Read-only. Initiating a departure belongs to the extension, where the
    /// bubble that carries it is composed; this is the receiving side's
    /// display, and tapping it opens the meetup on the map.
    ///
    /// Reads the `arrivalSync` MIRROR, never the store. This sits in the
    /// bottom sheet, which SwiftUI re-evaluates on every sheet drag frame —
    /// the two App Group reads plus two JSON decodes this used to do per
    /// evaluation are the same per-frame-state pattern the host lag audit
    /// already caught once.
    @ViewBuilder
    var arrivalSyncBanner: some View {
        if let sync = arrivalSync,
           let mine = myArrivalSyncEntry,
           mine.departureStatus != .departed,
           let travel = mine.estimatedTravelTime {
            let leaveNow = ArrivalSyncTiming.shouldLeaveNow(
                targetArrival: sync.targetArrivalTime, travelTime: travel)
            let tint = leaveNow ? Tokens.Palette.warning : Tokens.Palette.brand
            // The tap IS the reciprocal action the departure notice promised
            // ("tap to tell Hassan when you leave") — not a navigation
            // affordance. A banner that only reframed the map would leave that
            // prompt pointing at nothing.
            Button(action: sendArrivalSyncDeparture) {
                HStack(spacing: Tokens.Spacing.s3) {
                    TweenRowIcon(systemImage: leaveNow ? "figure.walk.motion" : "clock.fill",
                                 color: tint, size: 36)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(leaveNow ? "Time to go" : "\(sync.initiatedByName) is on the way")
                            .font(Tokens.Typography.subheadline.weight(.semibold))
                            .foregroundStyle(Tokens.Palette.textPrimary)
                            .lineLimit(1)
                        Text(arrivalSyncBannerDetail(sync: sync, mine: mine, leaveNow: leaveNow))
                            .font(Tokens.Typography.caption)
                            .foregroundStyle(Tokens.Palette.textSecondary)
                            // Scales before truncating — the leave time is the
                            // one thing this banner exists to show, and it must
                            // survive the largest Dynamic Type sizes.
                            .lineLimit(2)
                            .minimumScaleFactor(0.8)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 0)

                    Image(systemName: "chevron.right")
                        .font(Tokens.Typography.captionBold)
                        .foregroundStyle(Tokens.Palette.textTertiary)
                }
                .padding(Tokens.Spacing.s3)
                .background(Tokens.Palette.elevated,
                            in: RoundedRectangle(cornerRadius: Tokens.Radius.group, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, Tokens.Spacing.s4)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(leaveNow
                ? "Time to go. \(arrivalSyncBannerDetail(sync: sync, mine: mine, leaveNow: true))"
                : "\(sync.initiatedByName) is on the way. \(arrivalSyncBannerDetail(sync: sync, mine: mine, leaveNow: false))")
            .accessibilityHint("Tells everyone you have left for \(sync.destinationName)")
        }
    }

    func arrivalSyncBannerDetail(sync: ArrivalSyncState,
                                 mine: ArrivalParticipantState,
                                 leaveNow: Bool) -> String {
        if leaveNow {
            return "Leave now to reach \(sync.destinationName) around the same time."
        }
        guard let departure = mine.recommendedDepartureTime,
              let travel = mine.estimatedTravelTime else {
            return "Reaching \(sync.destinationName) around \(ArrivalSyncNotifier.timeFormatter.string(from: sync.targetArrivalTime))."
        }
        let minutes = ArrivalSyncTiming.leaveInMinutes(
            targetArrival: sync.targetArrivalTime, travelTime: travel)
        return "Leave in \(minutes) min · \(ArrivalSyncNotifier.timeFormatter.string(from: departure)) · tap when you go"
    }
}
