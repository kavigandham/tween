import Foundation
import os

/// Natural language → `MoodIntent`. The ONE seam between what a person types
/// and everything the search pipeline does with it.
///
/// Deterministic and local by design (see the header of `MoodIntent.swift`):
/// no network hop before the first MapKit request, nothing to key, nothing to
/// send anywhere. The contract is a single function, so an LLM-backed resolver
/// can replace the body later without the sheet or the search pipeline
/// noticing.
///
/// Three passes, in order, because the later ones depend on the earlier:
///
///   1. **Normalize** — case, punctuation, emoji, apostrophes, whitespace,
///      length. "WE'RE BORED!!! 😭" and "we're bored" must reach pass 2 as the
///      same string, or the vocabulary has to carry every shouting variant.
///   2. **Negations** — pull out "…but not food", "except a restaurant",
///      "no bars". The negated words are REMOVED from the text before pass 3:
///      leaving them in is how "something fun but not food" scores the food
///      family and returns exactly what the user said no to.
///   3. **Score** — longest-phrase-first keyword match over what's left.
///      Nothing matched → the `.open` family at `.low` confidence, which
///      searches broadly AND carries the user's own words (spec §10).
enum MoodIntentResolver {

    /// Anything past this is a paragraph, not a mood. MapKit's text engine
    /// degrades on long strings anyway, and the vocabulary match only ever
    /// looks at the first phrases that hit.
    static let maxQueryLength = 140

    /// Resolves what the user typed. Nil for blank/whitespace-only input —
    /// the sheet disables its CTA on exactly that condition.
    static func resolve(_ raw: String) -> MoodIntent? {
        let text = normalize(raw)
        guard !text.isEmpty else { return nil }

        let parsed = negations(in: text)
        let scored = bestFamily(in: parsed.remaining)

        var exclusions = parsed.exclusions
        // A positive "indoors"/"inside" is a constraint too: it means "no
        // parks, no trails" even though the user phrased it positively.
        if containsPhrase(parsed.remaining, ["indoors", "indoor", "inside"]) {
            exclusions.insert(.outdoors)
        }

        let family = scored?.family ?? .open
        // The family itself can carry a food exclusion ("something fun" is
        // explicitly not-food) — but only when the user didn't ask for food
        // in the same breath ("fun food spot").
        var resolvedExclusions = exclusions
        if family.foodPreference == .exclude,
           !containsPhrase(parsed.remaining, foodAffirmations) {
            resolvedExclusions.insert(.food)
        }

        return MoodIntent(
            originalQuery: text,
            family: family,
            focus: nil,
            merged: [],
            exclusions: resolvedExclusions,
            prefersClose: parsed.prefersClose,
            confidence: scored == nil ? .low : .high)
    }

    // MARK: - Pass 1: normalize

    /// Lowercased, stripped to letters/digits/spaces, apostrophes dropped
    /// (so "we're" → "were" and the vocabulary needs one spelling, not two),
    /// whitespace collapsed, length capped.
    static func normalize(_ raw: String) -> String {
        let deapostrophed = raw.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "")
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "-", with: " ")
        // Emoji, punctuation and every other symbol become separators rather
        // than being deleted, so "fun/chill" doesn't fuse into one token.
        let scalars = deapostrophed.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) { return Character(scalar) }
            return " "
        }
        let collapsed = String(scalars).split(separator: " ").joined(separator: " ")
        return collapsed.count > maxQueryLength
            ? String(collapsed.prefix(maxQueryLength)).trimmingCharacters(in: .whitespaces)
            : collapsed
    }

    // MARK: - Pass 2: negations

    struct ParsedNegations: Equatable {
        /// The text with every negated span removed, for scoring.
        var remaining: String
        var exclusions: Set<MoodExclusion>
        var prefersClose: Bool
    }

    /// Words that flip the meaning of what follows them.
    private static let negationCues: Set<String> =
        ["not", "no", "without", "except", "excluding", "besides", "minus", "nothing", "anti"]

    /// Skipped inside a negated span so "except a restaurant" reaches
    /// "restaurant".
    private static let spanStopwords: Set<String> = ["a", "an", "the", "any", "too", "really", "very"]

    /// How many words after a cue can still belong to it. Four covers
    /// "not a single ice cream" while stopping well short of swallowing the
    /// rest of the sentence.
    private static let spanLength = 4

    /// What each exclusion sounds like, longest phrase first so "ice cream"
    /// is matched before "cream" could partially hit.
    private static let exclusionVocabulary: [(phrase: String, exclusion: MoodExclusion)] = [
        ("ice cream", .iceCream), ("frozen yogurt", .iceCream), ("gelato", .iceCream),
        ("icecream", .iceCream), ("froyo", .iceCream),
        ("coffee shop", .coffee), ("coffee", .coffee), ("cafe", .coffee), ("espresso", .coffee),
        ("restaurants", .restaurants), ("restaurant", .restaurants),
        ("sit down", .restaurants),
        ("desserts", .dessert), ("dessert", .dessert), ("sweets", .dessert),
        ("sweet", .dessert), ("sugar", .dessert), ("bakery", .dessert),
        ("food", .food), ("eating", .food), ("eat", .food), ("meal", .food),
        ("dinner", .food), ("lunch", .food),
        ("bars", .bars), ("bar", .bars), ("drinking", .bars), ("drinks", .bars),
        ("alcohol", .bars), ("pub", .bars), ("clubbing", .bars), ("club", .bars),
        ("outdoors", .outdoors), ("outdoor", .outdoors), ("outside", .outdoors),
        ("indoors", .indoors), ("indoor", .indoors), ("inside", .indoors),
    ]

    /// Phrases that mean "keep it close" — the one distance constraint the
    /// vicinity screen can actually enforce.
    private static let closePhrases = ["too far", "far away", "long drive", "far"]

    /// Phrases that keep a not-food family (fun, crazy, competitive) from
    /// auto-excluding food: the user asked for both.
    private static let foodAffirmations =
        ["food", "eat", "dinner", "lunch", "brunch", "hungry", "restaurant", "snacks"]

    /// Splits the text into what the user wants and what they ruled out.
    static func negations(in text: String) -> ParsedNegations {
        let tokens = text.split(separator: " ").map(String.init)
        var exclusions: Set<MoodExclusion> = []
        var prefersClose = false
        var kept: [String] = []
        var index = 0

        while index < tokens.count {
            guard negationCues.contains(tokens[index]) else {
                kept.append(tokens[index])
                index += 1
                continue
            }
            // The cue itself is dropped either way.
            let spanEnd = min(index + 1 + spanLength, tokens.count)
            var span = Array(tokens[(index + 1)..<spanEnd])
            // Another cue ends this one ("not food not drinks").
            if let stop = span.firstIndex(where: { negationCues.contains($0) }) {
                span = Array(span[..<stop])
            }
            let meaningful = span.filter { !spanStopwords.contains($0) }
            let spanText = meaningful.joined(separator: " ")

            var consumed = 0
            if closePhrases.contains(where: { spanText.hasPrefix($0) }) {
                prefersClose = true
                consumed = matchedWordCount(in: spanText, phrases: closePhrases)
            } else if let hit = exclusionVocabulary.first(where: { spanText.hasPrefix($0.phrase) }) {
                exclusions.insert(hit.exclusion)
                // "no food" also means no restaurants; keeping them separate
                // would let the restaurant category back in through a merge.
                if hit.exclusion == .food { exclusions.insert(.restaurants) }
                consumed = hit.phrase.split(separator: " ").count
            }

            if consumed == 0 {
                // A cue we can't act on ("not sure", "no idea") — keep the
                // words so they can still score, and move past the cue only.
                index += 1
                continue
            }
            // Drop the cue plus the words it negated; everything after the
            // matched phrase stays available for scoring.
            var dropped = 0
            var cursor = index + 1
            while cursor < tokens.count, dropped < consumed {
                if !spanStopwords.contains(tokens[cursor]) { dropped += 1 }
                cursor += 1
            }
            index = cursor
        }

        return ParsedNegations(remaining: kept.joined(separator: " "),
                               exclusions: exclusions,
                               prefersClose: prefersClose)
    }

    private static func matchedWordCount(in text: String, phrases: [String]) -> Int {
        phrases.filter { text.hasPrefix($0) }
            .map { $0.split(separator: " ").count }
            .max() ?? 0
    }

    // MARK: - Pass 3: score

    struct Scored: Equatable {
        let family: MoodFamily
        let score: Int
    }

    /// Family vocabulary. A phrase scores its own word count, so a two-word
    /// phrase ("date night") always beats the single words inside it and
    /// "late night food" lands on `.lateNight` rather than `.food`.
    private static let vocabulary: [MoodFamily: [String]] = [
        .fun: ["something fun", "do something", "something to do", "things to do",
               "fun", "entertainment", "activity", "activities", "play", "games",
               "adventure", "arcade", "amusement"],
        .bored: ["we are bored", "were bored", "so bored", "nothing to do",
                 "kill time", "time to kill", "hours to kill", "to kill",
                 "mess around", "hang out", "hangout", "bored", "boring",
                 "entertain us", "entertain"],
        .sweet: ["sweet treat", "something sweet", "ice cream", "frozen yogurt",
                 "bubble tea", "milk tea", "dessert", "desserts", "sweets",
                 "sweet", "sugar", "boba", "cookies", "cookie", "bakery", "cake",
                 "donut", "doughnut", "gelato", "froyo", "candy", "chocolate",
                 "pastry", "treat"],
        .dateNight: ["date night", "date idea", "date ideas", "romantic",
                     "anniversary", "valentines", "first date", "date"],
        .crazy: ["go crazy", "high energy", "send it", "go wild", "get wild",
                 "crazy", "wild", "insane", "adrenaline", "rowdy", "extreme",
                 "hype", "turnt", "rage"],
        .chill: ["low key", "lowkey", "laid back", "catch up", "somewhere quiet",
                 "we can talk", "just talk", "chill", "relax", "relaxing",
                 "mellow", "quiet", "calm", "cozy", "unwind", "talk"],
        // "late night food" lives HERE, not under `.food`: the whole phrase
        // is a late-night ask, and scoring it in both families let the
        // 3-word phrase hand the query to a plain restaurant search.
        .lateNight: ["late night food", "late night", "open late", "after hours",
                     "midnight", "nightcap", "late"],
        .competitive: ["something competitive", "competitive", "compete",
                       "competition", "tournament", "versus", "beat them",
                       "bowling", "mini golf", "laser tag", "pickleball", "sports"],
        .outdoors: ["fresh air", "get outside", "something outside", "outside",
                    "outdoors", "outdoor", "nature", "scenic", "sunset",
                    "picnic", "hike", "trail", "walk", "park"],
        .food: ["grab a bite", "something to eat", "restaurant", "hungry",
                "starving", "dinner", "lunch", "brunch", "breakfast",
                "food", "eat", "meal"],
        .drinks: ["happy hour", "cocktail bar", "get drinks", "drinks", "drink",
                  "beer", "cocktails", "brewery", "winery", "wine", "pub", "bar"],
    ]

    /// Single words the fuzzy pass is allowed to correct toward. Short words
    /// are excluded: at four letters or fewer an edit distance of one is
    /// noise, not a typo ("bar" ⟷ "car").
    private static let fuzzyTargets: [(word: String, family: MoodFamily)] = {
        vocabulary.flatMap { family, phrases in
            phrases.filter { !$0.contains(" ") && $0.count >= 5 }
                .map { ($0, family) }
        }
    }()

    /// The best-matching family, or nil when nothing in the vocabulary
    /// appears — which is what makes the search fall back broadly instead of
    /// dead-ending.
    static func bestFamily(in text: String) -> Scored? {
        guard !text.isEmpty else { return nil }
        let padded = " \(text) "
        var scores: [MoodFamily: Int] = [:]

        for (family, phrases) in vocabulary {
            for phrase in phrases where padded.contains(" \(phrase) ") {
                scores[family, default: 0] += phrase.split(separator: " ").count
            }
        }

        if scores.isEmpty {
            // Nothing landed exactly — try once more allowing a single typo
            // per word ("desert" → "dessert", "competative" → "competitive").
            for token in text.split(separator: " ").map(String.init) where token.count >= 5 {
                for target in fuzzyTargets where isOneEditApart(token, target.word) {
                    scores[target.family, default: 0] += 1
                }
            }
        }
        guard let best = scores.max(by: { lhs, rhs in
            // Ties resolve by declaration order so the same input always
            // resolves the same way.
            lhs.value == rhs.value
                ? familyOrder(lhs.key) > familyOrder(rhs.key)
                : lhs.value < rhs.value
        }) else { return nil }
        return Scored(family: best.key, score: best.value)
    }

    /// Tie-break priority: the most SPECIFIC reading wins. "late night food"
    /// scores lateNight(2) and food(1) outright; a genuine tie like
    /// "competitive bowling" should read as competitive, not fun.
    private static func familyOrder(_ family: MoodFamily) -> Int {
        switch family {
        case .dateNight:   return 0
        case .lateNight:   return 1
        case .competitive: return 2
        case .sweet:       return 3
        case .crazy:       return 4
        case .outdoors:    return 5
        case .chill:       return 6
        case .bored:       return 7
        case .fun:         return 8
        case .drinks:      return 9
        case .food:        return 10
        case .open:        return 11
        }
    }

    /// True when one insert, delete, or substitution turns `a` into `b`.
    /// Bounded at distance 1 — a full Levenshtein matrix over every keyword
    /// on every keystroke-free resolve is cost with no payoff.
    static func isOneEditApart(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        let x = Array(a), y = Array(b)
        if abs(x.count - y.count) > 1 { return false }
        var i = 0, j = 0, edits = 0
        while i < x.count, j < y.count {
            if x[i] == y[j] { i += 1; j += 1; continue }
            edits += 1
            if edits > 1 { return false }
            if x.count == y.count { i += 1; j += 1 }
            else if x.count > y.count { i += 1 }
            else { j += 1 }
        }
        return edits + (x.count - i) + (y.count - j) <= 1
    }

    private static func containsPhrase(_ text: String, _ phrases: [String]) -> Bool {
        let padded = " \(text) "
        return phrases.contains { padded.contains(" \($0) ") }
    }
}

// MARK: - Stale-request guard

/// A monotonic ticket for the mood search.
///
/// `searchTask` cancellation already stops a superseded search, but a mood
/// search fans out into several concurrent MapKit requests and a cancelled
/// task's last `await` can still return before the check. Switching moods
/// quickly is the headline interaction here ("more competitive" → "more
/// chill" → back), so the publish step takes a ticket and refuses to write
/// anything but the newest — a search that cannot be stomped by an older one,
/// provable without the UI.
struct MoodRequestSequence: Equatable {
    private(set) var latest = 0

    /// Takes the newest ticket, invalidating every outstanding one.
    mutating func issue() -> Int {
        latest += 1
        return latest
    }

    /// True only for the most recently issued ticket.
    func isCurrent(_ ticket: Int) -> Bool { ticket == latest }

    /// Invalidates everything outstanding without issuing a new search — the
    /// sheet was dismissed, or the search was cleared.
    mutating func invalidate() { latest += 1 }
}

// MARK: - Analytics

/// Mood events.
///
/// Tween has no analytics backend and never will (hard constraint 8: no
/// server, no accounts). What exists is `EngagementStore`, a local nudge
/// engine — not a funnel — so mood events go to the unified log instead,
/// where they are readable on a device via Console during testing and go
/// nowhere else.
///
/// The user's RAW text is never logged. Constraint 6 makes the App Group
/// plaintext, and the privacy model here has no place for free-form user
/// input; only the resolved family/focus (a fixed, non-identifying
/// vocabulary) is recorded, marked `.public` so it is actually readable.
enum MoodAnalytics {
    private static let logger = Logger(subsystem: "com.kavigandham.TweenApp", category: "Mood")

    static func opened() {
        logger.info("mood_opened")
    }

    static func suggestionSelected(_ family: MoodFamily) {
        logger.info("mood_suggestion_selected family=\(family.rawValue, privacy: .public)")
    }

    /// `freeText` records only WHETHER the user typed, never what.
    static func querySubmitted(_ intent: MoodIntent, freeText: Bool) {
        logger.info("""
            mood_query_submitted family=\(intent.family.rawValue, privacy: .public) \
            confidence=\(intent.confidence == .low ? "low" : "high", privacy: .public) \
            exclusions=\(intent.exclusions.count, privacy: .public) \
            free_text=\(freeText, privacy: .public)
            """)
    }

    static func resultsLoaded(_ intent: MoodIntent, count: Int, broadened: Bool) {
        logger.info("""
            mood_results_loaded family=\(intent.family.rawValue, privacy: .public) \
            focus=\(intent.focus?.rawValue ?? "none", privacy: .public) \
            count=\(count, privacy: .public) broadened=\(broadened, privacy: .public)
            """)
    }

    static func refinementSelected(_ refinement: MoodRefinement) {
        logger.info("mood_refinement_selected refinement=\(refinement.id, privacy: .public)")
    }
}
