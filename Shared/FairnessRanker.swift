import Foundation
import MapKit

/// A candidate meetup place scored by how fairly it splits the drive between
/// two participants.
///
/// `score` is what the ranking sorts on (ascending — lower is better). It rolls
/// together how long the worse-off person has to drive and how confident we are
/// in the estimate: an exact route beats one we had to guess from straight-line
/// distance, so low-confidence spots are pushed down.
struct RankedSpot: Identifiable {
    let id: UUID
    let item: MKMapItem?
    let etaFromA: TimeInterval
    let etaFromB: TimeInterval
    /// How much we trust the ETAs: 1.0 for a real route, 0.5 for a distance
    /// fallback when directions failed.
    let confidence: Double

    /// The longer of the two drives — the experience of the worse-off friend.
    var worseETA: TimeInterval { max(etaFromA, etaFromB) }

    /// How lopsided the trip is. Smaller is fairer.
    var fairnessGap: TimeInterval { abs(etaFromA - etaFromB) }

    /// Ranking key (ascending). A flat 2-minute grace is forgiven, then the
    /// result is inflated for low-confidence estimates so guesses rank below
    /// spots with real routes.
    var score: Double { (worseETA - 120) / confidence }

    init(id: UUID = UUID(), item: MKMapItem?, etaFromA: TimeInterval, etaFromB: TimeInterval, confidence: Double) {
        self.id = id
        self.item = item
        self.etaFromA = etaFromA
        self.etaFromB = etaFromB
        self.confidence = confidence
    }

    #if DEBUG
    // Test/preview support — never compiled into a release build.
    init(etaFromA: TimeInterval, etaFromB: TimeInterval, confidence: Double) {
        self.init(id: UUID(), item: nil, etaFromA: etaFromA, etaFromB: etaFromB, confidence: confidence)
    }
    #endif
}

/// Drive-time fairness engine. Resolves automobile ETAs from both participants
/// to each candidate and orders them so the fairest, shortest trips surface
/// first.
enum FairnessRanker {
    /// Average urban driving speed used to estimate an ETA when a real route
    /// can't be resolved (~30 mph).
    private static let fallbackSpeed: Double = 13.4 // m/s

    /// Ranks `candidates` (first `cap` only) by fairness. Each candidate's two
    /// ETAs are resolved concurrently; failures fall back to a straight-line
    /// estimate at half confidence. Returned sorted by `score` ascending.
    static func rank(
        candidates: [MKMapItem],
        from a: CLLocationCoordinate2D,
        and b: CLLocationCoordinate2D,
        cap: Int
    ) async -> [RankedSpot] {
        let capped = Array(candidates.prefix(cap))

        let spots = await withTaskGroup(of: RankedSpot.self) { group -> [RankedSpot] in
            for item in capped {
                group.addTask {
                    await rankOne(item, from: a, and: b)
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

    /// Resolves both ETAs for a single candidate, concurrently.
    private static func rankOne(
        _ item: MKMapItem,
        from a: CLLocationCoordinate2D,
        and b: CLLocationCoordinate2D
    ) async -> RankedSpot {
        async let resultA = eta(from: a, to: item)
        async let resultB = eta(from: b, to: item)
        let (etaA, okA) = await resultA
        let (etaB, okB) = await resultB

        // A single failed leg drops confidence for the whole spot.
        let confidence = (okA && okB) ? 1.0 : 0.5
        return RankedSpot(item: item, etaFromA: etaA, etaFromB: etaB, confidence: confidence)
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

        do {
            let response = try await MKDirections(request: request).calculate()
            if let route = response.routes.first {
                return (route.expectedTravelTime, true)
            }
        } catch {
            // Fall through to the distance estimate.
        }

        let from = CLLocation(latitude: origin.latitude, longitude: origin.longitude)
        let dest = item.placemark.coordinate
        let to = CLLocation(latitude: dest.latitude, longitude: dest.longitude)
        let meters = from.distance(from: to)
        return (meters / fallbackSpeed, false)
    }
}
