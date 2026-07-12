import Foundation
import MapKit
import CoreLocation

/// One participant's drive time to a candidate spot.
struct ParticipantETA: Identifiable, Equatable {
    let id: String           // Participant.id
    let name: String
    let eta: TimeInterval    // seconds
    let fromRoute: Bool      // true → MKDirections succeeded; false → straight-line fallback

    init(id: String, name: String, eta: TimeInterval, fromRoute: Bool) {
        self.id = id
        self.name = name
        self.eta = eta
        self.fromRoute = fromRoute
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
    let id: UUID
    let item: MKMapItem?
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
    var score: Double { max(worstETA - 120, 0) / confidence }

    init(id: UUID = UUID(), item: MKMapItem?, etas: [ParticipantETA], confidence: Double) {
        self.id = id
        self.item = item
        self.etas = etas
        self.confidence = confidence
    }

    // MARK: - Legacy 2-person accessors
    //
    // Existing UI (ETAChip, SpotDetailCard, the bubble renderer) still reads
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
    init(id: UUID = UUID(), item: MKMapItem?, etaFromA: TimeInterval, etaFromB: TimeInterval, confidence: Double) {
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
        self.init(id: UUID(), item: nil, etaFromA: etaFromA, etaFromB: etaFromB, confidence: confidence)
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
    /// 2 ppl × 5 candidates = 10 routes; 5 ppl × 4 candidates = 20 routes.
    private static let maxTotalRouteCalls = 20

    /// Scales candidate count by participant count so total route calls stay
    /// under `maxTotalRouteCalls`. Always returns at least 3 candidates so the
    /// UI has something to choose from even in larger groups.
    static func recommendedCap(for participantCount: Int) -> Int {
        guard participantCount > 0 else { return 5 }
        return max(3, maxTotalRouteCalls / participantCount)
    }

    /// Ranks `candidates` (first `cap` only) by fairness across all
    /// participants. Each leg is resolved concurrently; failures fall back to
    /// a straight-line estimate at half confidence. Returned sorted by `score`
    /// ascending.
    static func rank(
        candidates: [MKMapItem],
        participants: [Participant],
        cap: Int
    ) async -> [RankedSpot] {
        guard !participants.isEmpty else { return [] }
        let capped = Array(candidates.prefix(cap))

        let spots = await withTaskGroup(of: RankedSpot.self) { group -> [RankedSpot] in
            for item in capped {
                group.addTask {
                    await rankOne(item, participants: participants)
                }
            }
            var results: [RankedSpot] = []
            for await spot in group {
                results.append(spot)
            }
            return results
        }

        return spots.sorted { $0.score < $1.score }
    }

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

    /// Resolves every participant's ETA to a single candidate, concurrently.
    private static func rankOne(
        _ item: MKMapItem,
        participants: [Participant]
    ) async -> RankedSpot {
        let etas = await withTaskGroup(of: (Int, ParticipantETA).self) { group -> [ParticipantETA] in
            for (index, participant) in participants.enumerated() {
                group.addTask {
                    let (eta, ok) = await Self.eta(from: participant.coordinate, to: item)
                    return (index, ParticipantETA(
                        id: participant.id,
                        name: participant.name,
                        eta: eta,
                        fromRoute: ok
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

    /// Returns the automobile ETA in seconds and whether it came from a real
    /// route. On any failure, estimates from straight-line distance.
    private static func eta(
        from origin: CLLocationCoordinate2D,
        to item: MKMapItem
    ) async -> (TimeInterval, Bool) {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: origin))
        request.destination = item
        request.transportType = .automobile

        // Timeout-guarded like the extension's MKLocalSearch: a single stalled
        // MKDirections leg would otherwise keep the whole `rank()` task group
        // pending forever, leaving the spinner up (post-push audit). On timeout,
        // error, or no route we fall through to the straight-line estimate.
        if let response = await calculateRoute(request, timeoutNanoseconds: routeTimeoutNanoseconds),
           let route = response.routes.first {
            return (route.expectedTravelTime, true)
        }

        let from = CLLocation(latitude: origin.latitude, longitude: origin.longitude)
        let dest = item.placemark.coordinate
        let to = CLLocation(latitude: dest.latitude, longitude: dest.longitude)
        let meters = from.distance(from: to)
        return (meters / fallbackSpeed, false)
    }

    /// Ceiling on a single route calculation before we fall back to the
    /// straight-line estimate — keeps one hung leg from stalling the ranking.
    private static let routeTimeoutNanoseconds: UInt64 = 10 * 1_000_000_000

    private static func calculateRoute(_ request: MKDirections.Request,
                                       timeoutNanoseconds: UInt64) async -> MKDirections.Response? {
        await withTaskGroup(of: MKDirections.Response?.self) { group in
            group.addTask {
                try? await MKDirections(request: request).calculate()
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                return nil
            }
            let response = await group.next() ?? nil
            group.cancelAll()
            return response
        }
    }
}
