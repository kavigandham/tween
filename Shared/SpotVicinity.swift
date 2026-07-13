import Foundation
import CoreLocation
import MapKit

/// Keeps candidate spots BETWEEN the participants.
///
/// MapKit's text search treats the request region as relevance guidance, not a
/// boundary — even midpoint-centered requests drift toward the nearest dense
/// commercial corridor, and the broadened fallback pass is unconstrained by
/// design. The soft centrality penalty in `FairnessRanker` reorders a pool but
/// can't fix one that is entirely off to one side (device feedback: two people
/// in a line, every suggestion off to the right). This applies the hard cut:
/// candidates outside a circle around the group's centroid — sized by how
/// spread out the group is — are dropped BEFORE ranking, relaxing only when
/// the area is genuinely sparse.
enum SpotVicinity {
    /// How far from the centroid still counts as "between" (meters): 75% of
    /// the group's spread (max centroid→participant distance) plus 2 km of
    /// slack, floored at 3 km so close-together groups keep a usable pool.
    static func radius(for participants: [Participant]) -> CLLocationDistance {
        let center = MapGeometry.centroid(of: participants)
        let centerLocation = CLLocation(latitude: center.latitude, longitude: center.longitude)
        let spread = participants
            .map { CLLocation(latitude: $0.latitude, longitude: $0.longitude).distance(from: centerLocation) }
            .max() ?? 0
        return max(spread * 0.75 + 2_000, 3_000)
    }

    /// Drops candidates outside the between-circle. Relaxes the cut (×1.5,
    /// ×2.5) when it would leave fewer than `minimumCount`, and falls back to
    /// the unfiltered pool as a last resort — a sparse area beats an empty
    /// list. Fewer than two participants → nothing to be "between" → no-op.
    static func filter(
        _ items: [MKMapItem],
        participants: [Participant],
        minimumCount: Int
    ) -> [MKMapItem] {
        guard participants.count >= 2, !items.isEmpty else { return items }
        let center = MapGeometry.centroid(of: participants)
        let centerLocation = CLLocation(latitude: center.latitude, longitude: center.longitude)
        let base = radius(for: participants)
        for multiplier in [1.0, 1.5, 2.5] {
            let kept = items.filter { item in
                let c = item.placemark.coordinate
                return CLLocation(latitude: c.latitude, longitude: c.longitude)
                    .distance(from: centerLocation) <= base * multiplier
            }
            if kept.count >= minimumCount { return kept }
        }
        return items
    }
}
