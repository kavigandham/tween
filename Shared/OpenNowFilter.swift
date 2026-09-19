import Foundation

/// The "show me places I can actually walk into" filter.
///
/// MapKit vends NO opening-hours data in any API (SDK headers checked through
/// iOS 26.5), but its TEXT engine honours the phrase "open now" server-side —
/// verified against the live index (2026-07-31: "coffee" at 2 AM returns 25
/// closed cafes, "coffee open now" returns the 8 that are 24-hour). This is
/// undocumented behaviour, so the whole filter is built to degrade into
/// "unfiltered results" rather than an error if Apple ever stops honouring it.
///
/// Two hard rules come with it, and both are the reason this lives in ONE
/// place rather than being re-implemented per surface (the host app had it;
/// the extension didn't, which is why the extension kept ranking shuttered
/// cafes):
///
///   1. It rides `naturalLanguageQuery` ONLY. `MKLocalPointsOfInterestRequest`
///      takes no query text, so a POI pass can't carry the filter — and
///      merging one back in re-adds exactly the closed places the filter
///      removed. Callers must SKIP their POI pass while this is on.
///   2. Never append the phrase twice; "coffee open now open now" is a
///      different, worse query.
enum OpenNowFilter {
    static let phrase = "open now"

    /// `query` with the hours phrase appended, when the filter is on and the
    /// user hasn't already typed it themselves.
    static func qualified(_ query: String, enabled: Bool) -> String {
        guard enabled, !query.lowercased().contains(phrase) else { return query }
        return query + " " + phrase
    }
}
