import Foundation
import MapKit
import CoreLocation


/// Combines MapKit's strict local search pass with its broader region-hint
/// fallback. A tiny strict result set is usually incomplete for category-style
/// searches, but exact duplicates from the fallback should not produce repeated
/// pins.
enum SearchResultMerger {
    /// Drops candidates wildly outside the search area. The region-hint pass
    /// treats the region as guidance only and happily returns name matches on
    /// the far side of the world when nothing local matches (probed
    /// 2026-07-31: "unlimited sushi" → Sushi Unlimited, Cebu City, 8,300 mi
    /// away). Screen every hint-pass result through this before merging.
    static func vicinityFiltered(_ items: [MKMapItem],
                                 around center: CLLocationCoordinate2D,
                                 maxMeters: CLLocationDistance) -> [MKMapItem] {
        let anchor = CLLocation(latitude: center.latitude, longitude: center.longitude)
        return items.filter { item in
            let coordinate = item.placemark.coordinate
            let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            return location.distance(from: anchor) <= maxMeters
        }
    }

    static func merge(local: [MKMapItem], fallback: [MKMapItem], minimumCount: Int) -> [MKMapItem] {
        let localItems = deduped(local)
        guard !localItems.isEmpty else { return deduped(fallback) }
        guard localItems.count < minimumCount else { return localItems }
        return deduped(localItems + fallback)
    }

    static func deduped(_ items: [MKMapItem]) -> [MKMapItem] {
        var seen: Set<String> = []
        var result: [MKMapItem] = []

        for item in items {
            let key = identity(for: item)
            guard seen.insert(key).inserted else { continue }
            result.append(item)
        }

        return result
    }

    private static func identity(for item: MKMapItem) -> String {
        let placemark = item.placemark
        let coordinate = placemark.coordinate
        let roundedLatitude = (coordinate.latitude * 100_000).rounded() / 100_000
        let roundedLongitude = (coordinate.longitude * 100_000).rounded() / 100_000
        let name = (item.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let address = (placemark.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return "\(name)|\(address)|\(roundedLatitude)|\(roundedLongitude)"
    }
}
