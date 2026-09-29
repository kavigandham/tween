import Foundation
import MapKit

/// Turns a resolved `MoodIntent` into map items, using the SAME two MapKit
/// engines every other Tween search uses — the POI-category browse and the
/// natural-language text pass — and nothing else.
///
/// The only thing new here is FAN-OUT. A mood means several place types at
/// once ("we're bored" is bowling *and* arcades *and* mini golf), and running
/// those in series would stack five 8-second deadlines on top of each other.
/// So:
///
///   * the POI engine gets ONE request carrying every category in the intent
///     (`MKPointOfInterestFilter` takes an array — no reason to ask five
///     times), and
///   * the text keywords go out CONCURRENTLY in a task group, capped at
///     `keywordCap` so a mood can never become a request storm.
///
/// Results are deduplicated before they are returned, because the same
/// bowling alley legitimately comes back from the category pass and from the
/// "bowling" text pass (spec §12).
///
/// Ranking is NOT done here and must never be: the caller hands these items
/// to `presentSearchResults`, which runs the existing `FairnessRanker` exactly
/// as it does for a typed search.
enum MoodPlaceSearch {

    /// At most this many text queries per pass. Five covers every family's
    /// keyword list; the cap is what stops a future 12-term family from
    /// quietly becoming twelve round-trips.
    static let keywordCap = 5

    /// One rung of the mood search.
    ///
    /// - Parameters:
    ///   - regionRequired: `true` pins results inside the meetup corridor
    ///     (iOS 18+); `false` is the broadened metro rung.
    ///   - sanityMeters: distance screen applied to every result — the same
    ///     guard that keeps a hint-pass from returning another continent.
    ///   - openNowOnly: when on, the POI pass is SKIPPED entirely. It takes no
    ///     query text, so it cannot carry Apple's server-side hours filter,
    ///     and merging it back in re-adds exactly the closed places the filter
    ///     removed (see `OpenNowFilter`).
    static func places(for intent: MoodIntent,
                       region: MKCoordinateRegion,
                       regionRequired: Bool,
                       sanityMeters: CLLocationDistance,
                       openNowOnly: Bool) async -> [MKMapItem] {
        guard !Task.isCancelled else { return [] }

        let categories = openNowOnly ? [] : intent.categories
        let keywords = Array(intent.keywords.prefix(keywordCap))
        let center = region.center

        let harvested = await withTaskGroup(of: [MKMapItem].self) { group -> [MKMapItem] in
            if !categories.isEmpty {
                group.addTask {
                    await categoryPass(categories: categories, region: region)
                }
            }
            for keyword in keywords {
                group.addTask {
                    await textPass(keyword: keyword, region: region,
                                   regionRequired: regionRequired, openNowOnly: openNowOnly)
                }
            }
            var all: [MKMapItem] = []
            for await chunk in group { all += chunk }
            return all
        }

        guard !Task.isCancelled else { return [] }
        let screened = SearchResultMerger.vicinityFiltered(
            harvested, around: center, maxMeters: sanityMeters)
        // Exclusions are applied AFTER the network work, not instead of it:
        // the category set already dropped what it could up front, and this
        // catches the places MapKit returned with no category at all.
        return intent.filtered(SearchResultMerger.deduped(screened))
    }

    /// Apple Maps' own category-button engine: one request, every category the
    /// mood means. Radius is clamped to `MKLocalPointsOfInterestRequest`'s
    /// hard cap — a far-apart group's region exceeds it, which errors the
    /// request outright and silently drops the whole pass (the bug that made
    /// category chips dead for distant pairs).
    private static func categoryPass(categories: [MKPointOfInterestCategory],
                                     region: MKCoordinateRegion) async -> [MKMapItem] {
        let halfSpanMeters = max(region.span.latitudeDelta, region.span.longitudeDelta) * 111_000 / 2
        let radius = min(max(halfSpanMeters, 1_000), MKLocalPointsOfInterestRequest.maxRadius)
        let request = MKLocalPointsOfInterestRequest(center: region.center, radius: radius)
        request.pointOfInterestFilter = MKPointOfInterestFilter(including: categories)
        return await DeadlinedSearch.mapItems(for: request)
    }

    /// The text engine, carrying the Open Now phrase when the filter is on.
    /// This is what covers iOS 17, where almost every activity category
    /// (bowling, go-karts, climbing) simply does not exist in the taxonomy.
    private static func textPass(keyword: String,
                                 region: MKCoordinateRegion,
                                 regionRequired: Bool,
                                 openNowOnly: Bool) async -> [MKMapItem] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = OpenNowFilter.qualified(keyword, enabled: openNowOnly)
        request.region = region
        request.resultTypes = .pointOfInterest
        if #available(iOS 18.0, *), regionRequired {
            request.regionPriority = .required
        }
        return await DeadlinedSearch.mapItems(for: request)
    }
}
