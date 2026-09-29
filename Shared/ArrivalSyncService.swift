import Foundation
import CoreLocation

/// Arrival Sync orchestration: the two moments, and nothing in between.
///
///   * `initiate` — somebody tapped **I Left**. Measure their fresh drive, turn
///     it into an arrival time, measure everyone else's leg from the origins
///     the roster already carries, and hand back a state the caller broadcasts
///     and stores.
///   * `receive` — an `.enroute` bubble carrying an arrival target arrived.
///     Re-measure THIS device's own leg fresh, arm the reminder (or say "leave
///     now"), and store.
///
/// Those are the only two entry points, on purpose. There is no refresh loop,
/// no timer, no observer and no background work — the reminder waits inside
/// `UNUserNotificationCenter`, which costs nothing and survives relaunch. The
/// one exception is `reconcile`, which the host app runs on foreground to
/// repair a reminder the extension could not arm; it is a repair pass over
/// stored state, not a tracker.
///
/// Routing goes through `FairnessRanker` (deadlined `MKDirections`, the same
/// path ranking uses) so there is one place in the app that knows how to time
/// a leg, and `MeetupPlan` supplies each person's travel mode.
enum ArrivalSyncService {
    /// Most legs one departure will measure.
    ///
    /// The extension runs this code too, under a ~120 MB ceiling (constraint
    /// 1), and each leg is an `MKDirections` round trip. Groups are small and
    /// the ranker's own cap is 5–8, so this bounds the worst case without ever
    /// biting a real meetup.
    static let maxMeasuredLegs = 8

    /// What `initiate` produced, or why it didn't.
    enum InitiationResult {
        case success(ArrivalSyncState)
        /// Location is unavailable and there is no stored origin to fall back
        /// on — the one case where Tween genuinely cannot answer.
        case noOrigin
        /// MapKit could not route the departing user's own leg. Deliberately
        /// NOT synchronised off the straight-line fallback: every other
        /// person's departure time is derived from this one number, so a guess
        /// here becomes a wrong instruction for the whole group.
        case routeUnavailable
    }

    // MARK: - Initiating

    /// `userTappedILeft`, in full.
    ///
    /// `origin` is the departing user's CURRENT location (freshly acquired by
    /// the caller, which owns the location manager in both processes), falling
    /// back to their cached origin — the spec's graceful degradation when
    /// When-In-Use permission is unavailable. Nothing here starts, stops, or
    /// polls location.
    static func initiate(meetingID: String,
                         destinationName: String,
                         destination: CLLocationCoordinate2D,
                         participants: [Participant],
                         departingID: String,
                         departingName: String,
                         origin: CLLocationCoordinate2D?,
                         departed: Set<String> = [],
                         plan: MeetupPlan = MeetupPlanStore.current,
                         revision: Int = 0,
                         now: Date = Date()) async -> InitiationResult {
        guard let origin else { return .noOrigin }

        // FRESH, always. The ETA shown when the place was chosen was measured
        // for a different moment and possibly a different traffic picture, and
        // everyone else's departure hangs off this number.
        let mine = await FairnessRanker.routedTravelTime(
            from: origin, to: destination, mode: plan.mode(for: departingID))
        guard mine.fromRoute else { return .routeUnavailable }

        let target = ArrivalSyncTiming.expectedArrival(travelTime: mine.seconds, now: now)
        var state = ArrivalSyncState(meetingID: meetingID,
                                     destinationName: destinationName,
                                     destinationCoordinate: destination,
                                     targetArrivalTime: target,
                                     initiatedBy: departingID,
                                     initiatedByName: departingName,
                                     createdAt: now,
                                     version: revision)
        // The initiator is departed by definition — they are the one who left.
        state.set(ArrivalParticipantState(participantID: departingID,
                                          displayName: departingName,
                                          estimatedTravelTime: mine.seconds,
                                          departureStatus: .departed,
                                          departedAt: now))

        // Everyone else, from the origins already in the roster. No new
        // location is collected for anyone, and none is sent.
        let measurable = measurableParticipants(participants,
                                                excluding: departingID,
                                                departed: departed)
        let legs = await measureLegs(measurable, to: destination, plan: plan)
        seed(&state,
             participants: participants,
             departingID: departingID,
             departed: departed,
             legs: legs,
             now: now)
        return .success(state)
    }

    /// Writes every roster member's slice into a sync and applies whatever
    /// legs were measured for them.
    ///
    /// Seeded from the WHOLE roster, departed peers included — `measurable`
    /// above has already dropped them from the ROUTING, which is the expensive
    /// part, but they still belong in the state. Seeding only the measurable
    /// set left the initiator's copy of the sync disagreeing with every
    /// receiver's, which builds from the full roster (see `receive`).
    /// `receive`'s "a second person left" branch looks a departing peer up by
    /// id, so a row missing here made it fall through and re-aim the whole
    /// group off that later departure instead of just marking them gone.
    ///
    /// Split out of `initiate` so these rules are testable: `initiate`'s first
    /// act is an `MKDirections` call, which a test bundle cannot rely on.
    static func seed(_ state: inout ArrivalSyncState,
                     participants: [Participant],
                     departingID: String,
                     departed: Set<String>,
                     legs: [String: TimeInterval],
                     now: Date = Date()) {
        for participant in participants
        where !participant.isManual && !participant.id.isEmpty && participant.id != departingID {
            var entry = ArrivalParticipantState(
                participantID: participant.id,
                displayName: UserName.peerDisplayName(participant.name))
            // A departed peer stays departed: their own `.enroute` already
            // said so, and `apply` would refuse them anyway.
            if departed.contains(participant.id) {
                entry.departureStatus = .departed
                state.set(entry)
                continue
            }
            state.set(entry)
            if let seconds = legs[participant.id] {
                state.apply(travelTime: seconds, for: participant.id, now: now)
            }
        }
    }

    // MARK: - Receiving

    /// What `receive` did, so the caller can tell the user the same thing the
    /// notification says.
    enum ReceptionResult: Equatable {
        /// A reminder is armed for this date.
        case armed(Date)
        /// This device should leave now — nothing to wait for.
        case leaveNow
        /// The event was a re-delivery of one already applied; nothing changed.
        case duplicate
        /// Nothing to do: the local user has already departed, or isn't in
        /// this meetup's roster.
        case notApplicable
        /// The event was superseded or is about a different destination.
        case stale
    }

    /// Applies an incoming departure to THIS device.
    ///
    /// Not Pro-gated, on purpose and by product decision: Pro gates
    /// INITIATING a sync, never receiving one. A free participant whose friend
    /// pays still gets told when to leave — otherwise the paying user's
    /// feature does not work, which is the wrong thing to sell.
    ///
    /// `localOrigin` is this device's own location (cached is fine — it is the
    /// origin the roster already broadcasts). Nothing is collected here.
    @discardableResult
    static func receive(event: TweenState,
                        meetingID: String,
                        localID: String,
                        localName: String,
                        localOrigin: CLLocationCoordinate2D?,
                        participants: [Participant],
                        departed: Set<String> = [],
                        plan: MeetupPlan = MeetupPlanStore.current,
                        now: Date = Date()) async -> ReceptionResult {
        // An `.enroute` bubble with no `arr` is a plain "leaving now"
        // announcement from a non-Pro sender (or an older build). It still
        // renders in the strip through `EnRouteLog`; it just cannot
        // synchronise anything, because there is no target.
        guard event.messageType == .enroute,
              let target = event.arrivalTarget,
              !event.text.isEmpty
        else { return .notApplicable }

        let departingID = event.senderID ?? event.senderName ?? ""
        guard !departingID.isEmpty, departingID != localID else { return .notApplicable }

        var incoming = ArrivalSyncState(
            meetingID: meetingID,
            destinationName: event.text,
            destinationCoordinate: event.coordinate,
            targetArrivalTime: target,
            initiatedBy: departingID,
            initiatedByName: event.senderName.map(UserName.peerDisplayName) ?? "Your friend",
            createdAt: now,
            version: event.revision ?? 0)

        let existing = ArrivalSyncStore.load(key: meetingID)
        if let existing {
            // Same event twice — the receiver tapped the bubble again, or the
            // extension and the host both decoded it. Identity is content-
            // based (`eventID`), so this needs no list of seen events.
            if existing.eventID == incoming.eventID {
                return await reapply(existing,
                                     meetingID: meetingID,
                                     localID: localID,
                                     localName: localName,
                                     localOrigin: localOrigin,
                                     event: event,
                                     plan: plan,
                                     now: now)
            }
            guard existing.supersedes(by: incoming) else { return .stale }
            // A SECOND person leaving does not re-aim the group (V1: the first
            // departure stays the target). Their event only marks them gone.
            if existing.destinationID == incoming.destinationID,
               existing.participant(departingID) != nil,
               existing.initiatedBy != departingID {
                var updated = existing
                updated.markDeparted(departingID, at: now)
                updated.version = max(existing.version, incoming.version)
                ArrivalSyncStore.save(updated, key: meetingID)
                ArrivalSyncNotifier.cancelReminder(meetingID: meetingID,
                                                   participantID: departingID)
                return await reapply(updated,
                                     meetingID: meetingID,
                                     localID: localID,
                                     localName: localName,
                                     localOrigin: localOrigin,
                                     event: event,
                                     plan: plan,
                                     now: now)
            }
            // A genuinely new sync replaces the old one — cancel what the old
            // one armed before its identifiers are forgotten.
            ArrivalSyncNotifier.cancelAll(meetingID: meetingID,
                                          participantIDs: existing.participants.map(\.participantID))
        }

        // Seed the roster so the whole group's plan is renderable here, not
        // only the local user's own row.
        incoming.set(ArrivalParticipantState(
            participantID: departingID,
            displayName: incoming.initiatedByName,
            estimatedTravelTime: event.etaSeconds.map(TimeInterval.init),
            departureStatus: .departed,
            departedAt: now))
        for participant in participants where participant.id != departingID {
            guard !participant.isManual else { continue }
            var entry = ArrivalParticipantState(
                participantID: participant.id,
                displayName: participant.id == localID
                    ? localName : UserName.peerDisplayName(participant.name))
            if departed.contains(participant.id) { entry.departureStatus = .departed }
            incoming.set(entry)
            // The initiator's own measurements, as a starting point. Each
            // device still re-measures ITS OWN leg below; this is what makes
            // the other rows renderable and what a device with no route falls
            // back to.
            if let seconds = event.travelSeconds[participant.id],
               entry.departureStatus != .departed {
                incoming.apply(travelTime: TimeInterval(seconds),
                               for: participant.id, now: now)
            }
        }

        return await reapply(incoming,
                             meetingID: meetingID,
                             localID: localID,
                             localName: localName,
                             localOrigin: localOrigin,
                             event: event,
                             plan: plan,
                             now: now)
    }

    /// Re-measures the LOCAL user's leg against a sync and arms accordingly.
    ///
    /// Split out because three paths need exactly this — a brand-new event, a
    /// re-delivered one, and the host's foreground repair — and the one thing
    /// they must not do differently is decide when to fire.
    private static func reapply(_ state: ArrivalSyncState,
                                meetingID: String,
                                localID: String,
                                localName: String,
                                localOrigin: CLLocationCoordinate2D?,
                                event: TweenState?,
                                plan: MeetupPlan,
                                now: Date) async -> ReceptionResult {
        var state = state
        guard let me = state.participant(localID) else {
            ArrivalSyncStore.save(state, key: meetingID)
            return .notApplicable
        }
        // Already said they left: no reminder, ever again.
        guard me.departureStatus != .departed else {
            ArrivalSyncNotifier.cancelReminder(meetingID: meetingID, participantID: localID)
            ArrivalSyncStore.save(state, key: meetingID)
            return .notApplicable
        }

        // Fresh route for MY leg. Falls back to whatever the initiator
        // measured for me, then to the straight-line number — a receiver has
        // nothing better to offer and a rough leave time beats silence.
        var travel = me.estimatedTravelTime
        if let localOrigin {
            let measured = await FairnessRanker.routedTravelTime(
                from: localOrigin,
                to: state.destinationCoordinate,
                mode: plan.mode(for: localID))
            if measured.fromRoute || travel == nil { travel = measured.seconds }
        }
        guard let travel else {
            // No origin and the initiator sent no leg for us. Store the sync
            // anyway: the UI can still say who left and where, and the host's
            // reconciliation will fill this in once a fix lands.
            ArrivalSyncStore.save(state, key: meetingID)
            return .notApplicable
        }

        state.apply(travelTime: travel, for: localID, now: now)
        ArrivalSyncStore.save(state, key: meetingID)

        let departure = ArrivalSyncTiming.recommendedDeparture(
            targetArrival: state.targetArrivalTime, travelTime: travel, now: now)
        let spot = state.destinationName
        let who = state.initiatedByName

        if ArrivalSyncTiming.shouldLeaveNow(targetArrival: state.targetArrivalTime,
                                            travelTime: travel, now: now) {
            // Nothing to schedule — and nothing pending should survive, or a
            // stale "time to go" from a previous target could still fire.
            ArrivalSyncNotifier.cancelReminder(meetingID: meetingID, participantID: localID)
            await ArrivalSyncNotifier.notifyLeaveNow(meetingID: meetingID,
                                                     departingID: state.initiatedBy,
                                                     departingName: who,
                                                     spotName: spot)
            return .leaveNow
        }

        await ArrivalSyncNotifier.notifyOnTheWay(meetingID: meetingID,
                                                 departingID: state.initiatedBy,
                                                 departingName: who,
                                                 spotName: spot,
                                                 departure: departure)
        // Nil (denied, or not yet granted) is not a failure: the departure
        // time is stored and rendered in-app either way.
        _ = await ArrivalSyncNotifier.scheduleReminder(meetingID: meetingID,
                                                       participantID: localID,
                                                       departingName: who,
                                                       spotName: spot,
                                                       departure: departure,
                                                       now: now)
        _ = event
        return .armed(departure)
    }

    // MARK: - This device departing

    /// Records that the LOCAL user has now left, against a sync somebody else
    /// started. Their own reminder is retired — Tween does not tell someone to
    /// leave after they have said they did.
    @discardableResult
    static func noteLocalDeparture(meetingID: String,
                                   localID: String,
                                   now: Date = Date()) -> ArrivalSyncState? {
        guard var state = ArrivalSyncStore.load(key: meetingID),
              state.participant(localID) != nil else { return nil }
        state.markDeparted(localID, at: now)
        ArrivalSyncStore.save(state, key: meetingID)
        ArrivalSyncNotifier.cancelReminder(meetingID: meetingID, participantID: localID)
        return state
    }

    // MARK: - Repair and cleanup

    /// Host-app foreground pass: arms a reminder the extension could not.
    ///
    /// The extension decodes the bubble but may be unable to schedule — it
    /// never requests notification permission (a permission alert must not
    /// appear over a conversation), so a user who had not yet granted it gets
    /// stored state and no reminder. This collects that, exactly as
    /// `LeaveByRefresher` collects an orphaned leave-by reminder, and it is
    /// also the contextually appropriate moment to ask: the user is looking at
    /// a meetup that is actively coordinating.
    ///
    /// Foreground-only and one-shot. Re-checking in the background would need
    /// Always location, which Tween does not ask for and does not need
    /// (constraint 4).
    @discardableResult
    static func reconcile(meetingID: String,
                          localID: String,
                          localName: String,
                          localOrigin: CLLocationCoordinate2D?,
                          plan: MeetupPlan = MeetupPlanStore.current,
                          now: Date = Date()) async -> ReceptionResult {
        guard let state = ArrivalSyncStore.load(key: meetingID) else { return .notApplicable }
        guard let me = state.participant(localID), me.departureStatus != .departed
        else { return .notApplicable }
        // Already armed for the right moment — leave it alone. Without this
        // every foreground would re-post the "on the way" notice.
        if let pending = await ArrivalSyncNotifier.pendingFireDate(meetingID: meetingID,
                                                                   participantID: localID),
           let expected = me.recommendedDepartureTime,
           abs(pending.timeIntervalSince(expected)) < ArrivalSyncTiming.leaveNowTolerance {
            return .armed(pending)
        }
        return await reapply(state,
                             meetingID: meetingID,
                             localID: localID,
                             localName: localName,
                             localOrigin: localOrigin,
                             event: nil,
                             plan: plan,
                             now: now)
    }

    /// Ends a sync and everything it armed: the meetup was cancelled, someone
    /// left the meetup, or the group changed the destination.
    static func cancel(meetingID: String) {
        // The STORED blob, not the expiry-filtered read: an expired sync can
        // still have live notification requests to retire, and reading the
        // filtering accessor here would find nothing and cancel nothing.
        guard let state = ArrivalSyncStore.stored(key: meetingID) else { return }
        ArrivalSyncNotifier.cancelAll(meetingID: meetingID,
                                      participantIDs: state.participants.map(\.participantID))
        ArrivalSyncStore.clear(key: meetingID)
    }

    /// Ends a sync only if it was for a DIFFERENT place than the group is now
    /// meeting at. Every departure time in it was derived from an arrival
    /// measured to somewhere else, so keeping it would tell people to leave at
    /// times that mean nothing; only a fresh I Left can re-establish it.
    @discardableResult
    static func invalidateIfDestinationChanged(meetingID: String,
                                              destinationName: String?,
                                              destination: CLLocationCoordinate2D?) -> Bool {
        guard let state = ArrivalSyncStore.stored(key: meetingID) else { return false }
        guard let destinationName, let destination else {
            // No settled place at all any more — the board reopened.
            cancel(meetingID: meetingID)
            return true
        }
        guard !state.matches(destinationName: destinationName, coordinate: destination)
        else { return false }
        cancel(meetingID: meetingID)
        return true
    }

    // MARK: - Helpers

    /// Who a departure measures legs for: real roster members other than the
    /// departing user, minus anyone already gone, bounded by `maxMeasuredLegs`.
    ///
    /// `manual:` participants are excluded — they are local planning points
    /// (an address you typed, a friend without the app), not people with a
    /// device that could receive a reminder, and measuring them would spend
    /// the leg budget on rows nobody can act on.
    static func measurableParticipants(_ participants: [Participant],
                                       excluding departingID: String,
                                       departed: Set<String>) -> [Participant] {
        participants
            .filter { !$0.isManual && !$0.id.isEmpty }
            .filter { $0.id != departingID }
            .filter { !departed.contains($0.id) }
            .prefix(maxMeasuredLegs)
            .map { $0 }
    }

    /// Measures several legs concurrently. Each is independently deadlined by
    /// `DeadlinedSearch`, so one stalled route cannot keep the group pending —
    /// the failure the ranker hit and fixed the same way.
    private static func measureLegs(_ participants: [Participant],
                                    to destination: CLLocationCoordinate2D,
                                    plan: MeetupPlan) async -> [String: TimeInterval] {
        guard !participants.isEmpty else { return [:] }
        return await withTaskGroup(of: (String, TimeInterval).self) { group in
            for participant in participants {
                group.addTask {
                    let seconds = await FairnessRanker.travelTime(
                        from: participant.coordinate,
                        to: destination,
                        mode: plan.mode(for: participant.id))
                    return (participant.id, seconds)
                }
            }
            var result: [String: TimeInterval] = [:]
            for await (id, seconds) in group { result[id] = seconds }
            return result
        }
    }
}
