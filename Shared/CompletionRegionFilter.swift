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

    static func filter<C: RegionFilterableCompletion>(
        _ completions: [C], tokens: CompletionRegionTokens?) -> [C] {
        guard let tokens, tokens.administrativeArea != nil || tokens.country != nil else {
            return completions
        }
        return completions.filter { shouldKeep(title: $0.title, subtitle: $0.subtitle, tokens: tokens) }
    }

    static func shouldKeep(title: String, subtitle: String,
                           tokens: CompletionRegionTokens) -> Bool {
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
}
