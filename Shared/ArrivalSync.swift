import Foundation
import CoreLocation

/// Arrival Sync — "I left, here's when you should go".
///
/// One person taps **I Left**; Tween measures their drive, turns it into an
/// absolute ARRIVAL TIME, and every other participant's device works backwards
/// from that arrival to their own departure time. Everyone walks in together.
///
/// EVENT-BASED, not live tracking. The whole feature is one calculation at one
/// moment (`userTappedILeft`), carried in the `.enroute` bubble that already
/// existed, and a local notification on each receiving device. There is no
/// polling, no background location, no server, no socket, and nothing
/// continuous anywhere — which is also why the synchronisation target is an
/// ABSOLUTE `Date` rather than "24 minutes from now": the receiver may open
/// that bubble five minutes later, and `now + eta` would hand them a target
/// five minutes too late. See `ArrivalSyncTiming.recommendedDeparture`.
///
/// Privacy: nothing here is a location. The wire carries an arrival timestamp
/// and per-person travel SECONDS; the origins those seconds were measured from
/// are the roster coordinates that already ride in every payload. Constraint 6
/// (App Group is unencrypted) is satisfied the same way — this store holds
/// times, ids and names, plus the destination the group already agreed on in
/// public.

// MARK: - Pure timing

/// The arithmetic, with no MapKit, no UserNotifications and no clock of its
/// own — every entry point takes `now`. That is what makes the cases from the
/// spec (24 vs 14, 15 vs 14.5, 60 vs 10) testable without a simulator, a
/// network, or a route.
enum ArrivalSyncTiming {
    /// Slack below which "leave in 43 seconds" is a worse instruction than
    /// "leave now". Also the threshold the receive side uses to decide between
    /// arming a reminder and firing immediately.
    static let leaveNowTolerance: TimeInterval = 60

    /// How long an Arrival Sync stays meaningful. Matches `EnRouteLog.ttl` on
    /// purpose: they describe the same departure, and a sync that outlived the
    /// strip it renders beside would arm a reminder for a meetup that is over.
    static let lifetime: TimeInterval = 2 * 60 * 60

    /// When the departing person is expected to walk in.
    static func expectedArrival(travelTime: TimeInterval, now: Date = Date()) -> Date {
        now.addingTimeInterval(max(travelTime, 0))
    }

    /// When this participant should leave to arrive alongside them.
    ///
    /// Clamped to `now`: the shorter-trip case (spec case 2 — Hassan 14 min,
    /// Shiraaz 24 min) produces a departure in the PAST, and "leave in
    /// -10 minutes" is not an instruction. Clamping is also what keeps the
    /// notification layer honest — `UNTimeIntervalNotificationTrigger` refuses
    /// a non-positive interval, and a past `UNCalendarNotificationTrigger`
    /// silently never fires while still reporting success (the 2026-08-04
    /// lesson in `LeaveByReminder`).
    static func recommendedDeparture(targetArrival: Date,
                                     travelTime: TimeInterval,
                                     now: Date = Date()) -> Date {
        max(now, targetArrival.addingTimeInterval(-max(travelTime, 0)))
    }

    /// Seconds until this participant should leave. Never negative.
    static func delay(targetArrival: Date,
                      travelTime: TimeInterval,
                      now: Date = Date()) -> TimeInterval {
        max(0, recommendedDeparture(targetArrival: targetArrival,
                                    travelTime: travelTime,
                                    now: now).timeIntervalSince(now))
    }

    /// True when there is no useful waiting to do. Covers three shapes with
    /// one rule: the equal-trip case (15 vs 15 → 0 s), the sub-minute case
    /// (15 vs 14.5 → 30 s) and the shorter-trip case (14 vs 24 → clamped to
    /// 0 s).
    static func shouldLeaveNow(targetArrival: Date,
                               travelTime: TimeInterval,
                               now: Date = Date()) -> Bool {
        delay(targetArrival: targetArrival, travelTime: travelTime, now: now) <= leaveNowTolerance
    }

    /// Whole minutes for display, never zero — a row that says "leave in
    /// 0 min" should have been the leave-now row instead, so callers check
    /// `shouldLeaveNow` first and this rounds up the remainder.
    static func leaveInMinutes(targetArrival: Date,
                               travelTime: TimeInterval,
                               now: Date = Date()) -> Int {
        let seconds = delay(targetArrival: targetArrival, travelTime: travelTime, now: now)
        return max(1, Int((seconds / 60).rounded()))
    }
}

// MARK: - State

/// Where one participant stands in an Arrival Sync.
enum ArrivalDepartureStatus: String, Codable, Equatable, Sendable {
    /// Has time in hand; a reminder is (or should be) armed.
    case waiting
    /// Should be walking out of the door — no reminder to arm, say it now.
    case leaveNow
    /// Has announced their own departure. Never reminded again.
    case departed
}

/// One participant's slice of an Arrival Sync.
///
/// `estimatedTravelTime` is seconds, measured once, by whichever device did
/// the measuring — the initiator computes everyone's from the roster origins
/// so it can SHOW "Shiraaz should leave in 10 min", and each receiving device
/// re-measures its own leg fresh before arming anything. No coordinate is
/// stored here: the origin these seconds came from is the roster's, which
/// already lives in the snapshot.
struct ArrivalParticipantState: Codable, Equatable, Sendable, Identifiable {
    let participantID: String
    var displayName: String
    var estimatedTravelTime: TimeInterval?
    var recommendedDepartureTime: Date?
    var departureStatus: ArrivalDepartureStatus
    var departedAt: Date?

    var id: String { participantID }

    init(participantID: String,
         displayName: String,
         estimatedTravelTime: TimeInterval? = nil,
         recommendedDepartureTime: Date? = nil,
         departureStatus: ArrivalDepartureStatus = .waiting,
         departedAt: Date? = nil) {
        self.participantID = participantID
        self.displayName = displayName
        self.estimatedTravelTime = estimatedTravelTime
        self.recommendedDepartureTime = recommendedDepartureTime
        self.departureStatus = departureStatus
        self.departedAt = departedAt
    }

    /// Tolerant decode, like every other stored model here: a field added in a
    /// later build must not make the whole blob throw and discard a live sync
    /// (the `MeetupPoll.decisionSeq` lesson).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        participantID = try c.decodeIfPresent(String.self, forKey: .participantID) ?? ""
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName) ?? ""
        estimatedTravelTime = try c.decodeIfPresent(TimeInterval.self, forKey: .estimatedTravelTime)
        recommendedDepartureTime = try c.decodeIfPresent(Date.self, forKey: .recommendedDepartureTime)
        departureStatus = try c.decodeIfPresent(ArrivalDepartureStatus.self,
                                                forKey: .departureStatus) ?? .waiting
        departedAt = try c.decodeIfPresent(Date.self, forKey: .departedAt)
    }
}

/// One Arrival Sync: a destination, a target arrival, and where everyone
/// stands against it.
///
/// Deliberately `participants` + `initiatedBy`, never `userA`/`userB` — the
/// group case (Hassan left; Shiraaz leaves in 10, Khanna in 5) is the same
/// calculation applied per person, and hard-coding a pair is the one decision
/// that would force a rewrite to get there.
struct ArrivalSyncState: Codable, Equatable, Sendable {
    /// The conversation this belongs to — `ConversationMeetupStore`'s key.
    let meetingID: String
    let destinationName: String
    let destinationLatitude: Double
    let destinationLongitude: Double
    /// The synchronisation target: when the FIRST person to leave arrives.
    /// V1 keeps this fixed for the life of the sync (the spec's "do not
    /// over-engineer dynamic group ETA optimization") — a second person
    /// tapping I Left marks themselves departed, it does not re-aim everyone.
    var targetArrivalTime: Date
    /// Participant id of whoever tapped I Left first.
    let initiatedBy: String
    var initiatedByName: String
    let createdAt: Date
    var participants: [ArrivalParticipantState]
    /// Payload revision of the event that produced this (`TweenState.revision`),
    /// so a later event supersedes an earlier one and a re-delivered one does
    /// not. 0 for a locally-initiated sync that never saw a revision.
    var version: Int

    init(meetingID: String,
         destinationName: String,
         destinationCoordinate: CLLocationCoordinate2D,
         targetArrivalTime: Date,
         initiatedBy: String,
         initiatedByName: String,
         createdAt: Date = Date(),
         participants: [ArrivalParticipantState] = [],
         version: Int = 0) {
        self.meetingID = meetingID
        self.destinationName = TweenState.boundedName(destinationName)
        self.destinationLatitude = destinationCoordinate.latitude
        self.destinationLongitude = destinationCoordinate.longitude
        self.targetArrivalTime = targetArrivalTime
        self.initiatedBy = initiatedBy
        self.initiatedByName = initiatedByName
        self.createdAt = createdAt
        self.participants = participants
        self.version = version
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        meetingID = try c.decodeIfPresent(String.self, forKey: .meetingID) ?? ""
        destinationName = try c.decodeIfPresent(String.self, forKey: .destinationName) ?? ""
        destinationLatitude = try c.decodeIfPresent(Double.self, forKey: .destinationLatitude) ?? 0
        destinationLongitude = try c.decodeIfPresent(Double.self, forKey: .destinationLongitude) ?? 0
        targetArrivalTime = try c.decodeIfPresent(Date.self, forKey: .targetArrivalTime) ?? .distantPast
        initiatedBy = try c.decodeIfPresent(String.self, forKey: .initiatedBy) ?? ""
        initiatedByName = try c.decodeIfPresent(String.self, forKey: .initiatedByName) ?? ""
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? .distantPast
        participants = try c.decodeIfPresent([ArrivalParticipantState].self,
                                             forKey: .participants) ?? []
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 0
    }

    var destinationCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: destinationLatitude, longitude: destinationLongitude)
    }

    /// Content identity of the destination, on the same 1e-4° (~11 m) epsilon
    /// `PollOption.id` and `TweenState.sameSpot(as:)` use — so "the same cafe
    /// measured on two devices" is one destination, and a genuinely different
    /// place is a different one.
    var destinationID: String {
        PollOption.key(name: destinationName,
                       latitude: destinationLatitude,
                       longitude: destinationLongitude)
    }

    /// Stable identity for ONE departure event. Two deliveries of the same
    /// bubble produce the same string, which is what makes arming idempotent
    /// without storing a list of seen events.
    var eventID: String {
        "\(meetingID)|\(initiatedBy)|\(destinationID)|\(Int(targetArrivalTime.timeIntervalSince1970))"
    }

    /// True once the sync is too old to act on.
    func isExpired(now: Date = Date()) -> Bool {
        // Anchored to the ARRIVAL, not to `createdAt`: a sync created for a
        // 90-minute drive is still live at minute 80.
        now.timeIntervalSince(targetArrivalTime) > ArrivalSyncTiming.lifetime
    }

    /// True when this sync is still about the place the group is meeting at.
    /// A changed destination invalidates it outright — the target arrival was
    /// measured against somewhere else, so every departure time derived from
    /// it is wrong, and only a fresh I Left can fix that.
    func matches(destinationName name: String, coordinate: CLLocationCoordinate2D) -> Bool {
        destinationID == PollOption.key(name: TweenState.boundedName(name),
                                        latitude: coordinate.latitude,
                                        longitude: coordinate.longitude)
    }

    func participant(_ id: String) -> ArrivalParticipantState? {
        participants.first { $0.participantID == id }
    }

    /// Everyone still expected to travel — who the UI lists and who reminders
    /// are armed for.
    var pending: [ArrivalParticipantState] {
        participants.filter { $0.departureStatus != .departed }
    }

    /// Records (or replaces) one participant's slice.
    mutating func set(_ participant: ArrivalParticipantState) {
        if let index = participants.firstIndex(where: { $0.participantID == participant.participantID }) {
            participants[index] = participant
        } else {
            participants.append(participant)
        }
    }

    /// Marks someone as gone: their own I Left, or their `.enroute` bubble.
    /// Clears the departure recommendation with it, so nothing downstream can
    /// still render "leave in 10 min" for a person already driving.
    mutating func markDeparted(_ participantID: String, at date: Date = Date()) {
        guard var entry = participant(participantID) else { return }
        entry.departureStatus = .departed
        entry.departedAt = date
        entry.recommendedDepartureTime = nil
        set(entry)
    }

    /// Applies one participant's freshly measured leg.
    ///
    /// No-op for a participant who has already departed — the spec's
    /// "already-departed participant receives no reminder", enforced in the
    /// model rather than at each call site so a new caller cannot miss it.
    mutating func apply(travelTime: TimeInterval,
                        for participantID: String,
                        now: Date = Date()) {
        guard var entry = participant(participantID),
              entry.departureStatus != .departed else { return }
        entry.estimatedTravelTime = travelTime
        let departure = ArrivalSyncTiming.recommendedDeparture(
            targetArrival: targetArrivalTime, travelTime: travelTime, now: now)
        entry.recommendedDepartureTime = departure
        entry.departureStatus = ArrivalSyncTiming.shouldLeaveNow(
            targetArrival: targetArrivalTime, travelTime: travelTime, now: now)
            ? .leaveNow : .waiting
        set(entry)
    }

    /// Whether `other` should replace this one.
    ///
    /// Newer REVISION wins, and an equal revision from the same event is a
    /// re-delivery (no change). A different destination always wins regardless
    /// of revision — the group moved, and the old target is meaningless.
    func supersedes(by other: ArrivalSyncState) -> Bool {
        if destinationID != other.destinationID { return true }
        if other.version != version { return other.version > version }
        return other.eventID != eventID && other.createdAt > createdAt
    }
}

// MARK: - Persistence

/// Per-conversation Arrival Sync state in the App Group.
///
/// Single-key atomic JSON per conversation, `MeetupSync.post()` after every
/// write — the same discipline as every other writer here, so the host app and
/// the extension can never read a torn sync. Survives termination and relaunch
/// because it is just a preference; nothing in it needs the process that wrote
/// it to still be alive.
enum ArrivalSyncStore {
    private static let prefix = "tween.arrivalSync."

    private static var defaults: UserDefaults? { LocationCache.sharedDefaults }

    /// The live sync for a chat, or nil when there is none (or it has expired).
    static func load(key conversationKey: String) -> ArrivalSyncState? {
        guard let data = defaults?.data(forKey: storageKey(conversationKey)),
              let state = try? JSONDecoder().decode(ArrivalSyncState.self, from: data)
        else { return nil }
        guard !state.isExpired() else {
            // Reap on read. There is no background pass here to do it, and an
            // expired sync left in place would keep rendering a leave time for
            // a meetup that is over.
            clear(key: conversationKey)
            return nil
        }
        return state
    }

    /// The sync as STORED — no expiry reaping. For callers that must reason
    /// about the blob itself (is there one to cancel?) rather than about a
    /// sync they are going to act on. Mirrors `MeetupPlanStore.storedPlan`,
    /// and exists for the same reason: reading the filtering accessor to ask
    /// "does a blob exist" is how cleanup paths end up doing nothing.
    static func stored(key conversationKey: String) -> ArrivalSyncState? {
        guard let data = defaults?.data(forKey: storageKey(conversationKey)) else { return nil }
        return try? JSONDecoder().decode(ArrivalSyncState.self, from: data)
    }

    static func save(_ state: ArrivalSyncState, key conversationKey: String? = nil) {
        let storage = conversationKey ?? state.meetingID
        guard !storage.isEmpty, let data = try? JSONEncoder().encode(state) else { return }
        defaults?.set(data, forKey: storageKey(storage))
        MeetupSync.post()
    }

    static func clear(key conversationKey: String) {
        guard defaults?.data(forKey: storageKey(conversationKey)) != nil else { return }
        defaults?.removeObject(forKey: storageKey(conversationKey))
        MeetupSync.post()
    }

    private static func storageKey(_ conversationKey: String) -> String {
        prefix + conversationKey
    }
}
