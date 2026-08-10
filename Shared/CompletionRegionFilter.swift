import Foundation
import MapKit

/// Screens typing suggestions against the meetup area.
///
/// `MKLocalSearchCompleter.region` is only a BIAS: a query with no local
/// footprint fills the dropdown with global name matches (probed 2026-07-31:
/// "shushi" → Shusha, Azerbaijan; "unlimited sushi" → five restaurants in the
/// Philippines). Completions carry no coordinates, so this filters on the
/// address text: keep rows whose title/subtitle mention the meetup's
/// state (or country when no state is known), plus category-style rows with
/// no address at all. US-centric by design — the worst case near a state
/// border is fewer suggestions, never far-away garbage.
///
/// Tokens come from ONE reverse-geocode of the search-region center; when no
/// tokens are known yet the filter passes everything through.
struct CompletionRegionTokens: Equatable {
    /// `CLPlacemark.administrativeArea` — "TX" or "Texas" depending on locale.
    let administrativeArea: String?
    /// `CLPlacemark.country` — "United States".
    let country: String?
}

protocol RegionFilterableCompletion {
    var title: String { get }
    var subtitle: String { get }
}

extension MKLocalSearchCompletion: RegionFilterableCompletion {}

enum CompletionRegionFilter {

    /// MapKit's own "…, Search Nearby" category suggestion — a browse, not an
    /// identified place. Always local, and the caller resolves it through the
    /// category/text engine rather than by identity.
    static func isSearchNearby(subtitle: String) -> Bool {
        subtitle.trimmingCharacters(in: .whitespaces)
            .caseInsensitiveCompare("Search Nearby") == .orderedSame
    }

    static func filter<C: RegionFilterableCompletion>(
        _ completions: [C], tokens: CompletionRegionTokens?, query: String? = nil) -> [C] {
        guard let tokens, tokens.administrativeArea != nil || tokens.country != nil else {
            return completions
        }
        let kept = completions.filter {
            shouldKeep(title: $0.title, subtitle: $0.subtitle, tokens: tokens, query: query)
        }
        // Filter, but NEVER to nothing. A deliberate far search — "sacremento"
        // from Virginia, a typo the name-prefix exemption below can't catch —
        // has no local footprint, so screening it out leaves the dropdown empty
        // and search feels broken (device report 2026-08-10). When nothing
        // local survives, show what MapKit actually found, exactly as Apple
        // Maps does. The anti-garbage screen still holds whenever ANY local row
        // exists: typing "shushi" keeps the local sushi places and still hides
        // Shusha, Azerbaijan.
        if kept.isEmpty && !completions.isEmpty { return completions }
        return kept
    }

    static func shouldKeep(title: String, subtitle: String,
                           tokens: CompletionRegionTokens, query: String? = nil) -> Bool {
        // A place the user NAMED passes anywhere: they typed the start of its
        // own name, so it's what they asked for — not a far-away letter
        // collision. "sacramento" → "Sacramento, CA" is a prefix match and
        // survives from any state; "shushi" → "Shusha" is NOT (the query isn't
        // a prefix of the name), so that stays subject to the region screen.
        // Mirrors Apple Maps, which surfaces a named city wherever you type it.
        if let query, namedByQuery(title: title, query: query) { return true }

        let subtitleTrimmed = subtitle.trimmingCharacters(in: .whitespaces)
        // Category-style rows ("Coffee — Search Nearby") are always local.
        if subtitleTrimmed.caseInsensitiveCompare("Search Nearby") == .orderedSame { return true }
        // No address anywhere ("Tennis Courts") → nothing to judge, keep.
        // An address-style TITLE with no subtitle ("Shusha, Azerbaijan")
        // must still pass the token check.
        if subtitleTrimmed.isEmpty && !title.contains(",") { return true }

        let haystack = " " + (title + " " + subtitle)
            .lowercased()
            .replacingOccurrences(of: ",", with: " ")
            .split(separator: " ")
            .joined(separator: " ") + " "

        func matches(_ token: String?) -> Bool {
            guard let token = token?.lowercased(), !token.isEmpty else { return false }
            return haystack.contains(" \(token) ")
        }
        if matches(tokens.administrativeArea) { return true }
        // US addresses reliably carry the state code, so a US admin mismatch
        // is a real out-of-state row — drop it. Elsewhere, subtitles often
        // omit the administrative area entirely ("12 Rue de Rivoli, Paris,
        // France" vs admin "Île-de-France"), so requiring it would kill every
        // legitimate local suggestion (post-push audit M3); fall back to the
        // country, which still drops the cross-continent name matches.
        let isUS = tokens.country?.caseInsensitiveCompare("United States") == .orderedSame
        if isUS, tokens.administrativeArea != nil { return false }
        return matches(tokens.country)
    }

    /// Whether `query` names the completion — its leading name token (before any
    /// comma) begins with the typed text. Requires ≥3 chars so a stray "sa"
    /// doesn't wave the whole world through the region screen.
    static func namedByQuery(title: String, query: String) -> Bool {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard q.count >= 3 else { return false }
        let name = title.lowercased()
        let head = name.split(separator: ",").first.map(String.init) ?? name
        return head.hasPrefix(q) || name.hasPrefix(q)
    }
}
