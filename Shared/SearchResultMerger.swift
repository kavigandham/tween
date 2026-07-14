import Foundation
import MapKit


/// Combines MapKit's strict local search pass with its broader region-hint
/// fallback. A tiny strict result set is usually incomplete for category-style
/// searches, but exact duplicates from the fallback should not produce repeated
/// pins.
enum SearchResultMerger {
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
