import Foundation
import UIKit

/// Rescue rewrites for a committed search that found nothing in the meetup
/// region.
///
/// MapKit's text engine understands a fixed vocabulary of concept phrases
/// ("all you can eat sushi", "convenience store") but returns ZERO in-region
/// results for phrasings outside it ("unlimited sushi") — and the old global
/// fallback then surfaced literal name matches on the far side of the world
/// (probed 2026-07-31: "unlimited sushi" → Sushi Unlimited, Cebu City,
/// 8,300 mi away). Instead of falling back globally, the search retries the
/// region with rewrites the engine does understand: qualifier words stripped
/// ("unlimited sushi" → "sushi"), then spelling corrected ("shushi" → "sushi",
/// which Apple's server-side correction misses when the typo collides with a
/// real place name — Shusha, Azerbaijan).
enum SearchQueryRewriter {

    /// Ordered rescue candidates for a zero-result query. Never contains the
    /// original query; may be empty when no rewrite applies.
    static func rewrites(for query: String) -> [String] {
        var candidates: [String] = []
        func add(_ text: String?) {
            guard let text, !text.isEmpty,
                  text.caseInsensitiveCompare(query) != .orderedSame,
                  !candidates.contains(where: { $0.caseInsensitiveCompare(text) == .orderedSame })
            else { return }
            candidates.append(text)
        }
        let stripped = strippedQualifiers(from: query)
        add(stripped)
        add(spellCorrected(query))
        if let stripped { add(spellCorrected(stripped)) }
        return candidates
    }

    /// The query with qualifier words removed ("unlimited", "cheap", "late
    /// night", ...), or nil when nothing was stripped or nothing remains.
    /// Qualifiers either mean nothing to MapKit's engine or actively hijack
    /// the interpretation ("cheap eats" → Walmart Supercenters); the head
    /// noun is the part it resolves well.
    static func strippedQualifiers(from query: String) -> String? {
        var text = " " + query.lowercased().replacingOccurrences(of: "-", with: " ") + " "
        for phrase in qualifiers {
            while let range = text.range(of: " \(phrase) ") {
                text.replaceSubrange(range, with: " ")
            }
        }
        let collapsed = text.split(separator: " ").joined(separator: " ")
        guard !collapsed.isEmpty,
              collapsed != query.lowercased().split(separator: " ").joined(separator: " ")
        else { return nil }
        return collapsed
    }

    /// The query with misspelled words replaced by the spell checker's top
    /// guess, or nil when nothing changed. Catches the typos Apple's
    /// server-side correction misses.
    static func spellCorrected(_ query: String) -> String? {
        let checker = UITextChecker()
        let language = Locale.preferredLanguages.first?
            .replacingOccurrences(of: "-", with: "_") ?? "en_US"
        var corrected = query
        var offset = 0
        while true {
            let nsText = corrected as NSString
            let range = checker.rangeOfMisspelledWord(
                in: corrected,
                range: NSRange(location: 0, length: nsText.length),
                startingAt: offset,
                wrap: false,
                language: language)
            guard range.location != NSNotFound else { break }
            if let guess = checker.guesses(forWordRange: range, in: corrected, language: language)?.first {
                corrected = nsText.replacingCharacters(in: range, with: guess)
                offset = range.location + (guess as NSString).length
            } else {
                offset = range.location + range.length
            }
        }
        return corrected.caseInsensitiveCompare(query) == .orderedSame ? nil : corrected
    }

    /// Longest phrases first so multi-word qualifiers are removed whole
    /// before their component words could partially match.
    private static let qualifiers: [String] = [
        "all you can eat", "hole in the wall", "open 24 hours",
        "kid friendly", "kids friendly", "family friendly", "dog friendly",
        "pet friendly", "date night", "late night", "open late", "open now",
        "right now", "near me", "close by", "around here",
        "unlimited", "bottomless", "cheap", "cheapest", "affordable",
        "budget", "expensive", "fancy", "upscale", "best", "good", "great",
        "top", "nice", "cool", "fun", "quiet", "cozy", "cute", "chill",
        "aesthetic", "trendy", "romantic", "popular", "famous", "authentic",
        "local", "nearby", "new", "open", "24/7",
    ]
}
