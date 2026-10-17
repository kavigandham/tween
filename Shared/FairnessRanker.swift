import Foundation
import MapKit
import CoreLocation

/// One participant's drive time to a candidate spot.
struct ParticipantETA: Identifiable, Equatable {
    let id: String           // Participant.id
    let name: String
    let eta: TimeInterval    // seconds
    let fromRoute: Bool      // true → MKDirections succeeded; false → straight-line fallback
    /// True when the planned travel mode could not be answered at all and this
    /// number is for DRIVING instead.
    ///
    /// Transit is the case that matters: Apple only answers transit ETAs where
    /// it has coverage, and the old code responded to "no transit here" by
    /// inventing a straight-line time at bus speed — presenting a confident
    /// "22 min by transit" in a town with no buses. A real driving number,
    /// labelled, beats a fabricated transit one (2026-08-04).
    let modeUnavailable: Bool

    init(id: String, name: String, eta: TimeInterval,
         fromRoute: Bool, modeUnavailable: Bool = false) {
        self.id = id
        self.name = name
        self.eta = eta
        self.fromRoute = fromRoute
        self.modeUnavailable = modeUnavailable
    }
}

/// A candidate meetup place scored by how fairly it splits the drive between
/// every participant.
///
/// `score` is what the ranking sorts on (ascending — lower is better). It rolls
/// together how long the worst-off person has to drive and how confident we are
/// in the estimate: a spot whose ETAs all came from real routes beats one we
/// had to guess from straight-line distance, so low-confidence spots are
/// pushed down.
struct RankedSpot: Identifiable {
    /// STABLE identity derived from the spot itself, not a fresh UUID per
    /// init. The extension paints straight-line estimates, then swaps routed
    /// results in for the SAME spots; with a random id every swap minted new
    /// identities, so a card the user tapped during the optimistic window lost
    /// its selection (and the map its focus) when routed landed, and SwiftUI
    /// rebuilt the whole list instead of diffing it — a needless per-swap
    /// hitch (audit 2026-08-08). A deterministic id makes the estimate and its
    /// routed replacement the same row.
    let id: String
    let item: MKMapItem?

    /// A spot's identity from its own content — name + coordinate rounded to
    /// ~1 m — so an estimate and its routed replacement collapse to one row.
    static func stableID(for item: MKMapItem?) -> String {
        guard let item else { return UUID().uuidString }
        let c = item.placemark.coordinate
        let lat = (c.latitude * 100_000).rounded()
        let lon = (c.longitude * 100_000).rounded()
        return "\(item.name ?? "spot")@\(Int(lat)),\(Int(lon))"
    }
    let etas: [ParticipantETA]
    /// Fraction of legs that came from a real route (1.0 = all real; 0.5 = all
    /// fallback). Penalises the score so guessed spots rank below real ones.
    let confidence: Double

    var worstETA: TimeInterval { etas.map(\.eta).max() ?? 0 }
    var bestETA: TimeInterval { etas.map(\.eta).min() ?? 0 }
    var fairnessSpread: TimeInterval { worstETA - bestETA }

    /// Ranking key (ascending). A flat 2-minute grace is forgiven, then the
    /// result is inflated for low-confidence estimates so guesses rank below
    /// spots with real routes. The numerator is clamped at 0: below the grace
    /// period a negative value divided by a SMALLER confidence would rank
    /// straight-line guesses ABOVE real routes (inverted penalty).
    ///
    /// Finally the user's max-drive-time preference scales the whole thing.
    /// It's deliberately a multiplier and not a filter — over-limit spots stay
    /// in the list, they just stop looking promising.
    var score: Double {
        max(worstETA - 120, 0) / confidence
            * DriveTimePreference.penaltyMultiplier(worstETA: worstETA)
    }

    /// True when this spot asks someone to drive longer than the user's
    /// preference — surfaced in the list so a demoted spot explains itself.
    var exceedsDriveLimit: Bool {
        DriveTimePreference.exceedsLimit(worstETA: worstETA)
    }

    init(id: String? = nil, item: MKMapItem?, etas: [ParticipantETA], confidence: Double) {
        self.id = id ?? Self.stableID(for: item)
        self.item = item
        self.etas = etas
        self.confidence = confidence
    }

    // MARK: - Legacy 2-person accessors
    //
    // Existing UI (SpotDetailCard, the bubble renderer) still reads
    // etaFromA/etaFromB/worseETA/fairnessGap. They keep working in the
    // 2-person case via computed accessors so this slice doesn't ripple into
    // every UI file. Slice 5 migrates those callers to iterate `etas` and we
    // drop these.

    var etaFromA: TimeInterval { etas.first?.eta ?? 0 }
    var etaFromB: TimeInterval { etas.count >= 2 ? etas[1].eta : (etas.first?.eta ?? 0) }
    var worseETA: TimeInterval { worstETA }
    var fairnessGap: TimeInterval { fairnessSpread }

    /// 2-person convenience init kept so existing call sites and tests build
    /// unchanged. Slice 5 removes this once UI callers are migrated.
    init(id: String? = nil, item: MKMapItem?, etaFromA: TimeInterval, etaFromB: TimeInterval, confidence: Double) {
        self.init(
            id: id,
            item: item,
            etas: [
                ParticipantETA(id: "A", name: "A", eta: etaFromA, fromRoute: confidence >= 1.0),
                ParticipantETA(id: "B", name: "B", eta: etaFromB, fromRoute: confidence >= 1.0)
            ],
            confidence: confidence
        )
    }

    #if DEBUG
    // Test/preview support — never compiled into a release build.
    init(etaFromA: TimeInterval, etaFromB: TimeInterval, confidence: Double) {
        self.init(item: nil, etaFromA: etaFromA, etaFromB: etaFromB, confidence: confidence)
    }
    #endif
}

/// Drive-time fairness engine. Resolves automobile ETAs from every participant
/// to each candidate and orders them so the fairest, shortest trips surface
/// first.
enum FairnessRanker {
    /// Average urban driving speed used to estimate an ETA when a real route
    /// can't be resolved (~30 mph).
    private static let fallbackSpeed: Double = 13.4 // m/s

    /// Total per-spot route calls cap. Keeps extension memory bounded:
    /// 2 ppl × 10 candidates = 20 routes; 5 ppl × 4 candidates = 20 routes.
    private static let maxTotalRouteCalls = 20
    /// Max penalty added for candidates at the edge of the participant spread.
    /// This keeps "fair" from drifting sideways away from the actual midpoint.
    private static let midpointPenaltyWeight: TimeInterval = 8 * 60

    /// Scales candidate count by participant count so total route calls stay
    /// under `maxTotalRouteCalls`. Always returns at least 3 candidates so the
    /// UI has something to choose from even in larger groups.
    static func recommendedCap(for participantCount: Int) -> Int {
        guard participantCount > 0 else { return 5 }
        return max(3, maxTotalRouteCalls / participantCount)
    }

    /// Produces an immediate, network-free ETA for every visible candidate.
    /// The host uses this while its capped set of real MapKit routes resolves,
    /// so a result never appears without participant times just because it fell
    /// below the routing cap (or because the user tapped its pin quickly).
    static func estimatedRankings(
        candidates: [MKMapItem],
        participants: [Participant]
    ) -> [RankedSpot] {
        guard !participants.isEmpty else { return [] }
        // ONE plan read for the whole pass. Read inside `estimatedSpot` it cost
        // two UserDefaults suite constructions plus a JSON decode per
        // candidate — 2N-cap decodes per search (audit 2026-08-02).
        let plan = MeetupPlanStore.current
        return sortedByFairness(
            candidates.map { estimatedSpot($0, participants: participants, plan: plan) },
            participants: participants)
    }

    /// Replaces the matching estimates with route-backed rankings, while
    /// retaining an estimated ranking for every other candidate. Route calls
    /// stay bounded by `cap`; time coverage does not.
    static func completeRankings(
        routed: [RankedSpot],
        allCandidates: [MKMapItem],
        participants: [Participant]
    ) -> [RankedSpot] {
        guard !participants.isEmpty else { return routed }
        let plan = MeetupPlanStore.current
        let completed = allCandidates.map { item in
            routed.first(where: { $0.item == item })
                ?? estimatedSpot(item, participants: participants, plan: plan)
        }
        return sortedByFairness(completed, participants: participants)
    }

    /// Decorate–sort–undecorate, because `rankedScore` is expensive and
    /// `sorted(by:)` calls it TWICE PER COMPARISON.
    ///
    /// One `rankedScore` does a UserDefaults read (the drive-time preference,
    /// via `spot.score`) plus two `MapGeometry.centroid` passes and one
    /// `CLLocation` per participant. At 40 candidates and 4 people that is
    /// ~430 comparisons → ~860 defaults reads and ~5000 `CLLocation`
    /// allocations, synchronously on the main actor, and it runs twice per
    /// search (estimate pass, then complete pass) plus once per re-rank.
    /// Scoring each spot ONCE makes it O(N) (lag audit 2026-10-13).
    ///
    /// `estimatedSpot` was already fixed for exactly this shape — see the
    /// "ONE plan read for the whole pass" note above.
    private static func sortedByFairness(_ spots: [RankedSpot],
                                         participants: [Participant]) -> [RankedSpot] {
        spots.map { ($0, rankedScore($0, participants: participants)) }
            .sorted { $0.1 < $1.1 }
            .map(\.0)
    }

    /// Ranks `candidates` (first `cap` only) by fairness across all
    /// participants. Each leg is resolved concurrently; failures fall back to
    /// a straight-line estimate at half confidence. Returned sorted by `score`
    /// ascending.
    /// The `cap` candidates closest to the point that balances everyone — the
    /// exact set `rank` routes. Exposed so the extension can pick the SAME set
    /// BEFORE its optimistic straight-line paint, instead of the first `cap` in
    /// MapKit relevance order, which dropped genuinely-fairer spots MapKit
    /// happened to rank lower (audit 2026-08-08).
    static func mostCentral(_ candidates: [MKMapItem], participants: [Participant], cap: Int) -> [MKMapItem] {
        guard !participants.isEmpty else { return Array(candidates.prefix(cap)) }
        // Distance computed ONCE per candidate: `centralityDistance` builds a
        // centroid and two CLLocations, and a comparator pays it twice per
        // comparison (lag audit 2026-10-13).
        return Array(candidates
            .map { ($0, centralityDistance(for: $0, participants: participants)) }
            .sorted { $0.1 < $1.1 }
            .map(\.0)
            .prefix(cap))
    }

    /// Ranks `candidates` against `participants`, resolving real routes.
    ///
    /// `onSpots` is called with the answers that landed SINCE THE LAST REPORT
    /// — a delta, not a running total — at most once every `reportInterval`,
    /// starting with the first arrival. Callers merge it into what they have
    /// already published; assigning it would wipe every earlier answer. A full
    /// rank is a few seconds of MapKit round-trips (measured 2.5-3 s for 8
    /// places and 2 people), and publishing only at the end meant every row
    /// sat on its straight-line estimate for that whole time and then changed
    /// at once. The ORDER is deliberately left to the caller's final
    /// `completeRankings`, so nothing jumps around under the user's finger
    /// while they read it (lag audit 2026-10-16).
    ///
    /// Whatever is still pending when the loop ends is NOT reported: the
    /// caller publishes the complete set immediately afterwards, so a final
    /// report would only buy an extra whole-screen pass.
    ///
    /// `reportInterval` is injectable for tests ONLY; no shipping caller
    /// passes it. At 0 every spot reports as it lands, which sharpens what a
    /// test can see: with the guard below deleted, a cancelled 3-candidate
    /// rank reports all 3 rather than just the first.
    ///
    /// It is the `.distantPast` anchor, NOT this parameter, that makes the
    /// guard observable at all — because the first arrival clears any finite
    /// window, a cancelled rank reports its first batch even at 0.4 s. Both
    /// were measured: guard deleted, default interval → 1 spot reported;
    /// guard deleted, interval 0 → 3. (An earlier version of this comment
    /// claimed the default could not fail, which was true of the `Date()`
    /// anchor it replaced and false the moment `.distantPast` landed in the
    /// same commit.)
    static func rank(
        candidates: [MKMapItem],
        participants: [Participant],
        cap: Int,
        reportInterval: TimeInterval = progressiveReportInterval,
        onSpots: (@MainActor ([RankedSpot]) -> Void)? = nil
    ) async -> [RankedSpot] {
        guard !participants.isEmpty else { return [] }
        let capped = mostCentral(candidates, participants: participants, cap: cap)

        let spots = await withTaskGroup(of: RankedSpot.self) { group -> [RankedSpot] in
            for item in capped {
                group.addTask {
                    await rankOne(item, participants: participants)
                }
            }
            var results: [RankedSpot] = []
            var pending: [RankedSpot] = []
            // `.distantPast`, not `Date()`: the FIRST answer to land reports
            // straight away. Starting the clock at the loop head delayed it by
            // a whole window for no gain, and on the two paths that cancel
            // without re-ranking (typing over a live list, backgrounding) a
            // window's worth of landed spots was simply discarded.
            var lastReport = Date.distantPast
            for await spot in group {
                results.append(spot)
                pending.append(spot)
                // NOT reported once this rank has been superseded. A cancelled
                // rank does not stop producing spots — `eta` resumes its legs
                // with nil and falls back to a straight-line estimate, so a
                // cancelled rank actually drains FASTER than a live one. Its
                // ids are content-derived (`name@lat,lon`), so they collide
                // with the new ranking's rows exactly when the two searches
                // overlap — which is every re-rank trigger there is: adding or
                // removing a person, changing a travel mode, Open Now, Search
                // here. Without this guard those stale half-confidence guesses
                // land ON TOP of routed answers, computed against the OLD
                // participant set, and nothing re-sorts them away.
                // Reported in BATCHES, not one at a time. Each report is a
                // `rankedSpots` write, and that is a whole-screen pass — Map,
                // every annotation, the group bar, the cards (~26 ms of
                // main-thread work, measured in an optimised build). Spot by
                // spot, a full ranking spent eight of them inside the 2.5-3 s
                // the user is staring at the list, which is the cost the two
                // commits before this one existed to remove. One write per
                // window keeps the rows filling in visibly while costing two
                // or three passes instead of eight.
                let now = Date()
                if let onSpots, !Task.isCancelled,
                   batchIsDue(now: now, lastReport: lastReport, interval: reportInterval) {
                    lastReport = now
                    let batch = pending
                    pending = []
                    await onSpots(batch)
                }
            }
            // Whatever is still pending needs no final report: the caller's
            // `completeRankings` publishes the whole set a moment later, and
            // an extra write here would just be a ninth pass.
            return results
        }

        return sortedByFairness(spots, participants: participants)
    }

    /// Replaces the entry for `spot`'s place with `spot`, IN PLACE — same
    /// index, same neighbours. Used to swap a straight-line estimate for its
    /// routed answer without moving the row. A spot with no match is ignored.
    ///
    /// That miss is NOT what makes this safe, and reading it that way is what
    /// shipped the bug in 8ced25d. `RankedSpot.id` is content-derived
    /// (`name@lat,lon`), so a superseded search produces ids that MATCH the
    /// new list's rows whenever the two searches overlap — which is every
    /// re-rank trigger there is. A stale spot reaching here replaces a live
    /// row; it does not bounce off. What keeps stale spots out is the
    /// cancellation guard in `rank` and the one in each caller's closure.
    static func merging(_ spot: RankedSpot, into spots: [RankedSpot]) -> [RankedSpot] {
        guard let index = spots.firstIndex(where: { $0.id == spot.id }) else { return spots }
        var merged = spots
        merged[index] = spot
        return merged
    }

    /// The batch form: every spot applied in place, for ONE published write.
    /// See `progressiveReportInterval` for why the batching exists.
    ///
    /// Folds through the single-spot form above so both shapes share one
    /// definition of "in place" — and so the invariant documented there is
    /// carried by code that actually runs, not by an overload nothing calls.
    static func merging(_ spots: [RankedSpot], into published: [RankedSpot]) -> [RankedSpot] {
        spots.reduce(published) { merging($1, into: $0) }
    }

    /// Whether a ranking in flight may publish now. Pure so the rule is
    /// testable: the shipping path (accumulate, then one write per window) is
    /// otherwise exercised by no test, because both callback tests pass
    /// `reportInterval: 0` and so never let `pending` accumulate at all
    /// (follow-up audit 2026-10-17).
    ///
    /// The `.distantPast` anchor is deliberate and load-bearing — see `rank`.
    static func batchIsDue(now: Date, lastReport: Date, interval: TimeInterval) -> Bool {
        now.timeIntervalSince(lastReport) >= interval
    }

    /// How often a ranking in flight may publish what has landed so far.
    /// Short enough that rows visibly fill in, long enough that a full
    /// ranking costs two or three whole-screen passes rather than one per
    /// candidate (lag audit 2026-10-17).
    static let progressiveReportInterval: TimeInterval = 0.4

    /// Legacy 2-person adapter. Existing callers (kickOffRanking, autoRank)
    /// invoke this until Slice 3/6 migrates them to pass real participant
    /// arrays from the conversation.
    static func rank(
        candidates: [MKMapItem],
        from a: CLLocationCoordinate2D,
        and b: CLLocationCoordinate2D,
        cap: Int
    ) async -> [RankedSpot] {
        let synthetic = [
            Participant(id: "A", name: "A", latitude: a.latitude, longitude: a.longitude),
            Participant(id: "B", name: "B", latitude: b.latitude, longitude: b.longitude)
        ]
        return await rank(candidates: candidates, participants: synthetic, cap: cap)
    }

    static func rankedScore(_ spot: RankedSpot, participants: [Participant]) -> TimeInterval {
        spot.score + centralityPenalty(for: spot.item, participants: participants)
    }

    static func centralityPenalty(for item: MKMapItem?, participants: [Participant]) -> TimeInterval {
        guard participants.count >= 2, let item else { return 0 }
        let distance = centralityDistance(for: item, participants: participants)
        let spread = max(participantSpread(participants), 500)
        return min(distance / spread, 2) * midpointPenaltyWeight
    }

    private static func centralityDistance(for item: MKMapItem, participants: [Participant]) -> CLLocationDistance {
        let center = MapGeometry.centroid(of: participants)
        return CLLocation(latitude: item.placemark.coordinate.latitude,
                          longitude: item.placemark.coordinate.longitude)
            .distance(from: CLLocation(latitude: center.latitude, longitude: center.longitude))
    }

    private static func participantSpread(_ participants: [Participant]) -> CLLocationDistance {
        let center = MapGeometry.centroid(of: participants)
        let centerLocation = CLLocation(latitude: center.latitude, longitude: center.longitude)
        return participants
            .map { CLLocation(latitude: $0.latitude, longitude: $0.longitude).distance(from: centerLocation) }
            .max() ?? 0
    }

    /// Resolves every participant's ETA to a single candidate, concurrently.
    private static func rankOne(
        _ item: MKMapItem,
        participants: [Participant]
    ) async -> RankedSpot {
        // Read the plan ONCE per spot, not once per leg: each read is two
        // UserDefaults suite lookups plus a JSON decode, and this runs on the
        // extension's hot path under a ~120 MB ceiling. Reading it per-leg also
        // meant a plan edited mid-ranking produced legs computed against
        // different plans (audit 2026-08-02). With no plan set this is
        // .driving / nil — byte-for-byte the old behaviour.
        let plan = MeetupPlanStore.current
        let etas = await withTaskGroup(of: (Int, ParticipantETA).self) { group -> [ParticipantETA] in
            for (index, participant) in participants.enumerated() {
                group.addTask {
                    let (eta, ok, modeMissing) = await Self.eta(
                        from: participant.coordinate,
                        to: item,
                        mode: plan.mode(for: participant.id),
                        arrivalDate: plan.arrivalDate)
                    return (index, ParticipantETA(
                        id: participant.id,
                        name: participant.name,
                        eta: eta,
                        fromRoute: ok,
                        modeUnavailable: modeMissing
                    ))
                }
            }
            var indexed: [(Int, ParticipantETA)] = []
            for await pair in group {
                indexed.append(pair)
            }
            // Preserve participant order so etas[i] corresponds to participants[i].
            return indexed.sorted { $0.0 < $1.0 }.map { $0.1 }
        }
        let realCount = etas.filter(\.fromRoute).count
        let confidence = etas.isEmpty ? 0.5 : (Double(realCount) / Double(etas.count)) * 0.5 + 0.5
        // All real → 1.0; all fallback → 0.5; mixed → linearly between.
        return RankedSpot(item: item, etas: etas, confidence: confidence)
    }

    /// One leg, for callers outside ranking: "how long from here to there,
    /// right now". Used by the extension's "Leaving now" button, which needs
    /// exactly one number and needs it to be honest — so this is the same
    /// deadlined MKDirections path the ranker uses, with the same
    /// straight-line fallback rather than a refusal.
    static func travelTime(from origin: CLLocationCoordinate2D,
                           to destination: CLLocationCoordinate2D,
                           mode: TravelMode = .driving) async -> TimeInterval {
        let item = MKMapItem(placemark: MKPlacemark(coordinate: destination))
        let (seconds, _, _) = await eta(from: origin, to: item, mode: mode)
        return seconds
    }

    /// One leg, WITH the provenance of the number.
    ///
    /// Same deadlined MKDirections path as `travelTime`, but it says whether
    /// the answer came from a real route or from the straight-line fallback.
    /// Arrival Sync needs the distinction and ranking does not: every
    /// candidate in a ranking is estimated the same way, so a guess only moves
    /// spots relative to each other — whereas telling somebody to walk out of
    /// the door at 6:10 off a crow-flies guess is a wrong instruction with
    /// nothing to compare it against. The initiator refuses to depart on
    /// `fromRoute == false` (the spec's "Couldn't calculate your ETA"), while
    /// a RECEIVER still uses it, because a rough departure time beats none.
    static func routedTravelTime(from origin: CLLocationCoordinate2D,
                                 to destination: CLLocationCoordinate2D,
                                 mode: TravelMode = .driving)
    async -> (seconds: TimeInterval, fromRoute: Bool) {
        let item = MKMapItem(placemark: MKPlacemark(coordinate: destination))
        let (seconds, fromRoute, _) = await eta(from: origin, to: item, mode: mode)
        return (seconds, fromRoute)
    }

    /// Returns the ETA in seconds and whether it came from a real route.
    /// On any failure, estimates from straight-line distance at the mode's
    /// own speed. Defaults reproduce the original driving-now behaviour.
    private static func eta(
        from origin: CLLocationCoordinate2D,
        to item: MKMapItem,
        mode: TravelMode = .driving,
        arrivalDate: Date? = nil
    ) async -> (TimeInterval, Bool, Bool) {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: origin))
        request.destination = item
        request.transportType = mode.transportType
        // Predicted traffic for when we'll actually arrive. MapKit ignores a
        // date in the past, so a stale plan degrades to "now" rather than
        // returning nothing.
        if let arrivalDate, arrivalDate > Date() {
            request.arrivalDate = arrivalDate
        }

        // Timeout-guarded like the extension's MKLocalSearch: a single stalled
        // MKDirections leg would otherwise keep the whole `rank()` task group
        // pending forever, leaving the spinner up (post-push audit). On timeout,
        // error, or no route we fall through to the straight-line estimate.
        //
        // Transit goes through calculateETA, not calculate: Apple does not vend
        // transit route geometry to third parties, so calculate() errors for
        // .transit even where transit ETAs are perfectly available. We only
        // ever want the duration anyway (constraint 2 forbids shipping route
        // geometry), so the ETA API is the correct call.
        if mode == .transit {
            if let seconds = await DeadlinedSearch.eta(
                for: request,
                seconds: TimeInterval(routeTimeoutNanoseconds) / 1_000_000_000) {
                return (seconds, true, false)
            }
            // No transit answer. Do NOT invent one at bus speed — ask for a
            // real driving route and say the mode was unavailable. A wrong
            // label on a true number is recoverable; a confident fabricated
            // number is not.
            let driving = MKDirections.Request()
            driving.source = MKMapItem(placemark: MKPlacemark(coordinate: origin))
            driving.destination = item
            driving.transportType = .automobile
            if let arrivalDate, arrivalDate > Date() { driving.arrivalDate = arrivalDate }
            if let response = await calculateRoute(driving, timeoutNanoseconds: routeTimeoutNanoseconds),
               let route = response.routes.first {
                return (route.expectedTravelTime, true, true)
            }
            let from = CLLocation(latitude: origin.latitude, longitude: origin.longitude)
            return (estimatedETA(from: from, to: item, mode: .driving), false, true)
        } else if let response = await calculateRoute(request, timeoutNanoseconds: routeTimeoutNanoseconds),
                  let route = response.routes.first {
            return (route.expectedTravelTime, true, false)
        }

        let from = CLLocation(latitude: origin.latitude, longitude: origin.longitude)
        return (estimatedETA(from: from, to: item, mode: mode), false, false)
    }

    /// Builds a complete low-confidence spot without making a directions
    /// request. Used only for visible candidates outside the route-call budget;
    /// any route-backed result replaces it through `completeRankings`.
    private static func estimatedSpot(
        _ item: MKMapItem,
        participants: [Participant],
        plan: MeetupPlan
    ) -> RankedSpot {
        // Honour the plan's travel modes here too. These estimates are what the
        // UI shows FIRST and what every candidate outside the route budget keeps
        // permanently, so leaving this on car speed reproduced the exact
        // "an hour on foot ranked as a fair ten-minute trip" bug the routed path
        // fixed (audit 2026-08-02). The plan is passed in, not read here — this
        // runs once per CANDIDATE.
        let etas = participants.map { participant in
            let origin = CLLocation(latitude: participant.latitude, longitude: participant.longitude)
            return ParticipantETA(
                id: participant.id,
                name: participant.name,
                eta: estimatedETA(from: origin, to: item,
                                  mode: plan.mode(for: participant.id)),
                fromRoute: false)
        }
        return RankedSpot(item: item, etas: etas, confidence: 0.5)
    }

    /// Straight-line fallback. The mode's own speed matters here: inheriting a
    /// car's speed for a walking leg would rank an hour on foot as a fair
    /// ten-minute trip.
    private static func estimatedETA(from origin: CLLocation,
                                     to item: MKMapItem,
                                     mode: TravelMode = .driving) -> TimeInterval {
        let destination = item.placemark.coordinate
        let destinationLocation = CLLocation(
            latitude: destination.latitude,
            longitude: destination.longitude)
        let speed = mode == .driving ? fallbackSpeed : mode.fallbackMetresPerSecond
        return origin.distance(from: destinationLocation) / speed
    }

    /// Ceiling on a single route calculation before we fall back to the
    /// straight-line estimate — keeps one hung leg from stalling the ranking.
    private static let routeTimeoutNanoseconds: UInt64 = 10 * 1_000_000_000

    private static func calculateRoute(_ request: MKDirections.Request,
                                       timeoutNanoseconds: UInt64) async -> MKDirections.Response? {
        // DeadlinedSearch.route, NOT a task-group race: a task group awaits
        // its unfinished children on scope exit, so a throttled calculate()
        // that ignores cancellation blocked this "timeout" exactly when it
        // mattered — the ranking spinner hung forever (post-push audit).
        await DeadlinedSearch.route(
            for: request,
            seconds: TimeInterval(timeoutNanoseconds) / 1_000_000_000)
    }
}
