import Foundation
import MapKit
import CoreLocation

/// How one person is getting to the meetup.
///
/// Fairness only ever needs the travel TIME, never the route geometry
/// (constraint 2), which is what makes transit viable here: Apple does not
/// vend transit route steps to third parties, but it does answer
/// `MKDirections.calculateETA` for transit in covered regions.
enum TravelMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case driving
    case transit
    case walking

    var id: String { rawValue }

    var transportType: MKDirectionsTransportType {
        switch self {
        case .driving: return .automobile
        case .transit: return .transit
        case .walking: return .walking
        }
    }

    var title: String {
        switch self {
        case .driving: return "Driving"
        case .transit: return "Transit"
        case .walking: return "Walking"
        }
    }

    var systemImage: String {
        switch self {
        case .driving: return "car.fill"
        case .transit: return "tram.fill"
        case .walking: return "figure.walk"
        }
    }

    /// Rough metres-per-second used when routing fails and we fall back to a
    /// straight-line estimate. Driving keeps the ranker's original constant;
    /// the others exist so a transit or walking leg doesn't silently inherit a
    /// car's speed and rank a spot as fair when it's an hour on foot.
    var fallbackMetresPerSecond: Double {
        switch self {
        case .driving: return 11.5   // ~26 mph door-to-door with stops
        case .transit: return 6.5    // ~15 mph including waiting and transfers
        case .walking: return 1.3    // ~3 mph
        }
    }
}

/// Tween Pro's planning layer: WHEN the meetup is, and HOW each person gets
/// there. Absent a plan, Tween behaves exactly as it always has — leave now,
/// everybody drives — so this is purely additive to the free flow.
///
/// Local planning data only. It seeds ranking and reminders on this device and
/// is never broadcast in a payload (constraint 2 caps `MSMessage.url` at 5000
/// chars and carries coordinates + spot name only).
struct MeetupPlan: Codable, Equatable, Sendable {
    /// When everyone should ARRIVE. Nil means "meeting now" — the free
    /// behaviour. Arrival rather than departure is the honest model for
    /// "let's meet at 7": MapKit predicts each person's travel for the traffic
    /// expected at that time, and each person's leave-by time falls out of it.
    var arrivalDate: Date?

    /// Participant id → mode. Missing means driving, so a plan never has to
    /// enumerate everyone.
    var modes: [String: TravelMode]

    /// Which spot this schedule is FOR. Without it every spot card read
    /// "Planned" off one global flag, and a reminder set for one place quietly
    /// replaced another's (audit 2026-08-02). Travel modes stay global — how
    /// you get around isn't per-destination.
    var spotName: String?

    /// The planned spot's coordinate, so the plan can be reopened (and its
    /// calendar event placed) even after the search results that produced it
    /// are gone. Local planning data — never broadcast (constraint 2).
    var spotLatitude: Double?
    var spotLongitude: Double?

    init(arrivalDate: Date? = nil,
         modes: [String: TravelMode] = [:],
         spotName: String? = nil,
         coordinate: CLLocationCoordinate2D? = nil) {
        self.arrivalDate = arrivalDate
        self.modes = modes
        self.spotName = spotName
        self.spotLatitude = coordinate?.latitude
        self.spotLongitude = coordinate?.longitude
    }

    var coordinate: CLLocationCoordinate2D? {
        guard let spotLatitude, let spotLongitude else { return nil }
        return CLLocationCoordinate2D(latitude: spotLatitude, longitude: spotLongitude)
    }

    mutating func setSpot(name: String?, coordinate: CLLocationCoordinate2D?) {
        spotName = name
        spotLatitude = coordinate?.latitude
        spotLongitude = coordinate?.longitude
    }

    static let none = MeetupPlan()

    var isScheduled: Bool { arrivalDate != nil }

    /// True when at least one person isn't driving — the case the ranker has
    /// to fan out per-participant instead of using one shared transport type.
    var isMixedMode: Bool { modes.values.contains { $0 != .driving } }

    func mode(for participantID: String) -> TravelMode {
        modes[participantID] ?? .driving
    }

    mutating func setMode(_ mode: TravelMode, for participantID: String) {
        if mode == .driving {
            modes.removeValue(forKey: participantID)
        } else {
            modes[participantID] = mode
        }
    }

    /// Only meaningful for a scheduled plan: when this person has to leave to
    /// arrive on time, given a travel duration.
    func leaveBy(travelTime: TimeInterval) -> Date? {
        arrivalDate.map { $0.addingTimeInterval(-travelTime) }
    }
}

/// App Group persistence for the active plan. Single-key atomic JSON like every
/// other writer here, so a reader never sees a torn plan.
enum MeetupPlanStore {
    private static let key = "tween.meetupPlan"

    // Cached suite (lag audit 2026-08-08) — see LocationCache.sharedDefaults.
    private static var defaults: UserDefaults? { LocationCache.sharedDefaults }

    static var current: MeetupPlan {
        // Planning is Pro. Gating the READ (not just the editor) means a plan
        // saved while subscribed stops skewing ranking the moment Pro lapses,
        // rather than quietly living on. The stored plan is kept, so it comes
        // back intact if they resubscribe.
        guard ProEntitlement.isUnlocked else { return .none }
        guard let data = defaults?.data(forKey: key),
              let plan = try? JSONDecoder().decode(MeetupPlan.self, from: data) else {
            return .none
        }
        // A plan whose arrival time has already passed is stale — meeting "at
        // 7pm" yesterday must not keep skewing today's ranking or fire a
        // leave-by reminder for a meetup that already happened.
        if let arrival = plan.arrivalDate, arrival < Date().addingTimeInterval(-3600) {
            return MeetupPlan(arrivalDate: nil, modes: plan.modes)
        }
        return plan
    }

    /// True only when a schedule exists AND it's for this spot — so the badge
    /// appears on the planned card, not on every card.
    static func isScheduled(for spotName: String) -> Bool {
        let plan = current
        return plan.isScheduled && plan.spotName == spotName
    }

    static func save(_ plan: MeetupPlan) {
        guard let data = try? JSONEncoder().encode(plan) else { return }
        defaults?.set(data, forKey: key)
        MeetupSync.post()
    }

    static func clear() {
        defaults?.removeObject(forKey: key)
        MeetupSync.post()
    }

    /// Ends the meetup's SCHEDULE while preserving the user's modes — in BOTH
    /// entitlement states. Built for the leave paths: a modes-preserving save
    /// through `current` destroyed a lapsed subscriber's dormant blob, because
    /// the gated read returns `.none` (empty modes) when locked — the exact
    /// blob the gate's own comment promises to keep for resubscribe
    /// (audit 2026-08-06). Reads the RAW blob and no-ops when none exists, so
    /// a user who never planned gains no blob and no Darwin round-trip.
    static func endMeetup() {
        guard let plan = storedPlan else { return }
        save(MeetupPlan(arrivalDate: nil, modes: plan.modes))
    }

    /// The plan as STORED — no entitlement gate, no stale-arrival rewrite.
    /// Callers that must reason about the blob itself (does it exist? does it
    /// still carry a schedule?) use this; everything user-facing uses
    /// `current`. Reading the gated `current` for such questions is what made
    /// a locked user's leave look like "no plan" and destroy their data
    /// (audits 2026-08-06).
    static var storedPlan: MeetupPlan? {
        guard let data = defaults?.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(MeetupPlan.self, from: data)
    }
}
