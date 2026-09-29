import Foundation
import MapKit
import os

/// "What's the mood?" — natural language → a structured place intent.
///
/// The discovery gap this fills: every other search surface in Tween assumes
/// the user already knows WHAT they want (a chip, a category, a name). "we're
/// bored" / "sweet treat" / "go crazy" names a feeling, not a place, and the
/// text engine answers those with literal name matches ("Bored", "Crazy
/// Buffet") — the same failure mode that made the Study chip dead before it
/// was routed through the POI engine (see `CategoryPreset`).
///
/// So a mood is resolved LOCALLY, deterministically, into the same two things
/// every other search here speaks: `MKPointOfInterestCategory` values for the
/// POI-category engine, and plain terms the text engine already understands.
/// Nothing after that point is new — the mood search rides
/// `resolveMoodPlaces` → `presentSearchResults` → `FairnessRanker`, exactly
/// like a chip.
///
/// **No LLM, on purpose.** Tween has no server and no accounts (hard
/// constraint 8), so an LLM resolver would mean an API key in the client
/// (constraint 5) and a network hop before the first request goes out. The
/// resolver is therefore a keyword/synonym table behind ONE entry point,
/// `MoodIntentResolver.resolve(_:)` — swap its body for a remote call later
/// and neither the sheet nor the search pipeline changes.

// MARK: - Vocabulary

/// How much energy the mood is asking for. Display + note copy only; MapKit
/// has no energy signal to filter on.
enum MoodEnergy: String, Equatable {
    case low, medium, high
}

/// Where food sits in the mood.
enum MoodFoodPreference: String, Equatable {
    /// Food is welcome but not the point ("date night").
    case include
    /// The user said no food ("something fun but not food").
    case exclude
    /// Food IS the ask ("late night food").
    case only
}

/// A constraint the user stated in the negative.
///
/// Only constraints MapKit's data can actually enforce are modelled. Price
/// ("nothing expensive"), crowd level, and group size are NOT here: MapKit
/// vends no price band, occupancy, or capacity in any API, and pretending
/// otherwise would filter on nothing. `prefersClose` is the one exception
/// that IS enforceable — it tightens the vicinity screen, which is real
/// geometry.
enum MoodExclusion: String, CaseIterable, Equatable {
    case food
    case restaurants
    case dessert
    case iceCream
    case bars
    case coffee
    case outdoors
    case indoors

    /// POI categories this exclusion removes — from the search set BEFORE the
    /// requests go out, and from the results after.
    var excludedCategories: [MKPointOfInterestCategory] {
        var categories: [MKPointOfInterestCategory]
        switch self {
        case .food:        categories = [.restaurant, .cafe, .bakery, .foodMarket]
        case .restaurants: categories = [.restaurant]
        case .dessert:     categories = [.bakery]
        case .iceCream:    categories = []          // name-only: no POI category exists
        case .bars:        categories = [.nightlife, .brewery, .winery]
        case .coffee:      categories = [.cafe]
        case .outdoors:    categories = [.park, .nationalPark, .beach, .campground]
        case .indoors:     categories = [.movieTheater, .museum, .theater, .aquarium, .library]
        }
        if #available(iOS 18.0, *) {
            switch self {
            case .outdoors: categories += [.hiking, .fishing, .kayaking, .skatePark, .golf]
            case .indoors:  categories += [.bowling, .rockClimbing]
            default: break
            }
        }
        return categories
    }

    /// Name fragments that mean this exclusion even when MapKit attaches no
    /// category — which it frequently doesn't. Single words are matched on
    /// token boundaries (so "bar" never eats "Barnes & Noble"); multi-word
    /// phrases are matched as substrings.
    var excludedNameTerms: [String] {
        switch self {
        case .food, .restaurants:
            return ["restaurant", "grill", "kitchen", "diner", "pizzeria", "taqueria",
                    "eatery", "bistro", "steakhouse", "buffet", "cantina"]
        case .dessert:
            return ["dessert", "desserts", "ice cream", "creamery", "gelato",
                    "frozen yogurt", "froyo", "bakery", "donut", "doughnut",
                    "cupcake", "patisserie", "candy", "chocolatier"]
        case .iceCream:
            return ["ice cream", "creamery", "gelato", "frozen yogurt", "froyo",
                    "sundae", "cold stone", "baskin", "dairy queen", "scoop shop"]
        case .bars:
            return ["bar", "pub", "tavern", "brewery", "brewing", "taproom",
                    "saloon", "cocktail", "cocktails", "lounge", "distillery"]
        case .coffee:
            return ["coffee", "espresso", "roaster", "roasters", "roasting",
                    "cafe", "café", "starbucks", "dunkin"]
        case .outdoors, .indoors:
            return []
        }
    }
}

/// A narrower pool inside a family, selected by a refinement chip ("Ice
/// cream", "Boba", "Dinner"). Replaces the family's own categories/keywords
/// rather than adding to them — that's what makes it a REFINEMENT.
enum MoodFocus: String, CaseIterable, Equatable {
    case iceCream, boba, cookies, cafe, dinner, activity, dessert

    var displayName: String {
        switch self {
        case .iceCream: return "Ice cream"
        case .boba:     return "Boba"
        case .cookies:  return "Cookies"
        case .cafe:     return "Cafés"
        case .dinner:   return "Dinner"
        case .activity: return "Activities"
        case .dessert:  return "Dessert"
        }
    }

    var emoji: String {
        switch self {
        case .iceCream: return "🍦"
        case .boba:     return "🧋"
        case .cookies:  return "🍪"
        case .cafe:     return "☕️"
        case .dinner:   return "🍽"
        case .activity: return "🎳"
        case .dessert:  return "🍰"
        }
    }

    var poiCategories: [MKPointOfInterestCategory] {
        var categories: [MKPointOfInterestCategory]
        switch self {
        case .iceCream, .cookies, .dessert: categories = [.bakery, .cafe]
        case .boba, .cafe:                  categories = [.cafe, .bakery]
        case .dinner:                       categories = [.restaurant]
        case .activity:                     categories = [.amusementPark, .movieTheater, .museum]
        }
        if #available(iOS 18.0, *), self == .activity {
            categories += [.bowling, .miniGolf, .goKart, .rockClimbing, .skating]
        }
        return categories
    }

    var keywords: [String] {
        switch self {
        case .iceCream: return ["ice cream", "gelato", "frozen yogurt"]
        case .boba:     return ["boba", "bubble tea", "milk tea"]
        case .cookies:  return ["cookies", "bakery", "cookie shop"]
        case .cafe:     return ["coffee shop", "cafe"]
        case .dinner:   return ["restaurant", "dinner"]
        case .activity: return ["bowling", "arcade", "mini golf", "escape room"]
        case .dessert:  return ["dessert", "bakery", "ice cream"]
        }
    }
}

// MARK: - Families

/// The intent families a mood resolves into. One family per "kind of evening",
/// not one per place type — the whole point is that the user said a feeling.
enum MoodFamily: String, CaseIterable, Equatable {
    case fun
    case bored
    case sweet
    case dateNight
    case crazy
    case chill
    case lateNight
    case competitive
    case outdoors
    case food
    case drinks
    /// Nothing matched — deliberately broad, so the resolver never dead-ends
    /// (spec §10). Searches entertainment + activities + cafés + dessert +
    /// parks alongside whatever the user actually typed.
    case open

    var displayName: String {
        switch self {
        case .fun:         return "Something fun"
        case .bored:       return "We're bored"
        case .sweet:       return "Sweet treat"
        case .dateNight:   return "Date night"
        case .crazy:       return "Go crazy"
        case .chill:       return "Something chill"
        case .lateNight:   return "Late night"
        case .competitive: return "Competitive"
        case .outdoors:    return "Something outside"
        case .food:        return "Somewhere to eat"
        case .drinks:      return "Drinks"
        case .open:        return "Anything nearby"
        }
    }

    var emoji: String {
        switch self {
        case .fun:         return "🎳"
        case .bored:       return "😭"
        case .sweet:       return "🍦"
        case .dateNight:   return "❤️"
        case .crazy:       return "⚡️"
        case .chill:       return "😌"
        case .lateNight:   return "🌙"
        case .competitive: return "🏆"
        case .outdoors:    return "🌳"
        case .food:        return "🍽"
        case .drinks:      return "🍸"
        case .open:        return "✨"
        }
    }

    /// SF Symbol for the suggestion chip in the sheet (the chip rail speaks
    /// Label + systemImage everywhere else in Tween).
    var symbol: String {
        switch self {
        case .fun:         return "figure.bowling"
        case .bored:       return "zzz"
        case .sweet:       return "birthday.cake.fill"
        case .dateNight:   return "heart.fill"
        case .crazy:       return "bolt.fill"
        case .chill:       return "cup.and.saucer.fill"
        case .lateNight:   return "moon.stars.fill"
        case .competitive: return "trophy.fill"
        case .outdoors:    return "tree.fill"
        case .food:        return "fork.knife"
        case .drinks:      return "wineglass.fill"
        case .open:        return "sparkles"
        }
    }

    var energy: MoodEnergy {
        switch self {
        case .crazy, .competitive:       return .high
        case .fun, .bored, .outdoors:    return .medium
        case .sweet, .dateNight, .chill,
             .lateNight, .food, .drinks,
             .open:                      return .low
        }
    }

    var foodPreference: MoodFoodPreference {
        switch self {
        case .food, .lateNight:                 return .only
        case .fun, .crazy, .competitive:        return .exclude
        case .sweet, .dateNight, .chill,
             .bored, .outdoors, .drinks, .open: return .include
        }
    }

    /// Categories available since iOS 13.
    private var baseCategories: [MKPointOfInterestCategory] {
        switch self {
        case .fun, .bored:
            return [.amusementPark, .movieTheater, .museum, .aquarium, .zoo, .theater]
        case .sweet:
            return [.bakery, .cafe]
        case .dateNight:
            return [.restaurant, .cafe, .bakery, .movieTheater, .theater, .museum, .park]
        case .crazy:
            return [.amusementPark, .stadium, .fitnessCenter]
        case .chill:
            return [.cafe, .bakery, .park, .library, .museum]
        case .lateNight:
            return [.restaurant, .nightlife, .cafe]
        case .competitive:
            return [.stadium, .fitnessCenter]
        case .outdoors:
            return [.park, .nationalPark, .beach, .campground, .zoo]
        case .food:
            return [.restaurant]
        case .drinks:
            return [.nightlife, .brewery, .winery]
        case .open:
            return [.amusementPark, .movieTheater, .cafe, .bakery, .park, .restaurant]
        }
    }

    /// Categories added in iOS 18 — where almost every ACTIVITY lives
    /// (bowling, go-karts, mini golf, climbing). On iOS 17 the same moods are
    /// still served by the text keywords below, which is the whole reason
    /// both engines are kept in play.
    @available(iOS 18.0, *)
    private var modernCategories: [MKPointOfInterestCategory] {
        switch self {
        case .fun, .bored:
            return [.bowling, .miniGolf, .goKart, .skating, .rockClimbing]
        case .sweet:
            return []
        case .dateNight:
            return [.miniGolf, .musicVenue, .spa]
        case .crazy:
            return [.goKart, .rockClimbing, .skatePark, .skating]
        case .chill:
            return [.spa]
        case .lateNight:
            return [.musicVenue]
        case .competitive:
            return [.bowling, .miniGolf, .goKart, .golf, .tennis, .basketball,
                    .soccer, .volleyball, .rockClimbing]
        case .outdoors:
            return [.hiking, .skatePark, .golf, .tennis, .basketball, .swimming]
        case .food, .drinks:
            return []
        case .open:
            return [.bowling, .miniGolf]
        }
    }

    /// Everything the POI engine should browse for this mood.
    var poiCategories: [MKPointOfInterestCategory] {
        var categories = baseCategories
        if #available(iOS 18.0, *) { categories += modernCategories }
        return categories
    }

    /// Terms MapKit's TEXT engine actually understands. These carry the moods
    /// iOS 17 has no category for, and they carry the `open now` filter (the
    /// POI engine takes no query text — see `OpenNowFilter`).
    ///
    /// Deliberately short: each term is one network round-trip, and they are
    /// issued concurrently (spec §12).
    var keywords: [String] {
        switch self {
        case .fun:
            return ["bowling", "arcade", "mini golf", "escape room", "trampoline park"]
        case .bored:
            return ["arcade", "bowling", "mini golf", "escape room", "entertainment center"]
        case .sweet:
            return ["ice cream", "boba", "cookies", "dessert"]
        case .dateNight:
            return ["restaurant", "dessert", "mini golf", "rooftop bar", "scenic overlook"]
        case .crazy:
            return ["go karts", "axe throwing", "paintball", "trampoline park", "laser tag"]
        case .chill:
            return ["coffee shop", "bookstore", "dessert", "park"]
        case .lateNight:
            return ["late night food", "24 hour restaurant", "diner", "bar"]
        case .competitive:
            return ["bowling", "go karts", "mini golf", "laser tag", "pickleball"]
        case .outdoors:
            return ["park", "hiking trail", "scenic overlook", "lake"]
        case .food:
            return ["restaurant"]
        case .drinks:
            return ["bar", "brewery", "cocktail bar"]
        case .open:
            return ["entertainment", "things to do", "coffee shop", "dessert", "park"]
        }
    }

    /// The refinement chips offered under the results for this family
    /// (spec §8). Tapping one re-runs the SAME pipeline with an adjusted
    /// intent — never a fresh start.
    var refinements: [MoodRefinement] {
        switch self {
        case .fun, .bored:
            return [.replace(.competitive, title: "More competitive", symbol: "trophy.fill"),
                    .replace(.chill, title: "More chill", symbol: "leaf.fill"),
                    .merge(.sweet, title: "Add dessert", symbol: "birthday.cake.fill")]
        case .sweet:
            return [.focus(.iceCream), .focus(.boba), .focus(.cookies), .focus(.cafe)]
        case .dateNight:
            return [.focus(.dinner), .focus(.activity), .focus(.dessert),
                    .replace(.lateNight, title: "Late night", symbol: "moon.stars.fill")]
        case .crazy:
            return [.replace(.competitive, title: "Competitive", symbol: "trophy.fill"),
                    .replace(.chill, title: "More chill", symbol: "leaf.fill"),
                    .merge(.sweet, title: "Add dessert", symbol: "birthday.cake.fill")]
        case .chill:
            return [.focus(.cafe),
                    .merge(.sweet, title: "Add dessert", symbol: "birthday.cake.fill"),
                    .replace(.outdoors, title: "Outside", symbol: "tree.fill")]
        case .lateNight:
            return [.focus(.dinner), .focus(.dessert),
                    .replace(.drinks, title: "Drinks", symbol: "wineglass.fill")]
        case .competitive:
            return [.replace(.chill, title: "More chill", symbol: "leaf.fill"),
                    .replace(.fun, title: "Just fun", symbol: "figure.bowling"),
                    .merge(.sweet, title: "Add dessert", symbol: "birthday.cake.fill")]
        case .outdoors:
            return [.replace(.chill, title: "More chill", symbol: "leaf.fill"),
                    .focus(.activity),
                    .merge(.sweet, title: "Add dessert", symbol: "birthday.cake.fill")]
        case .food:
            return [.focus(.dinner), .merge(.sweet, title: "Add dessert", symbol: "birthday.cake.fill"),
                    .replace(.drinks, title: "Drinks", symbol: "wineglass.fill")]
        case .drinks:
            return [.focus(.dinner),
                    .replace(.lateNight, title: "Late night", symbol: "moon.stars.fill"),
                    .replace(.chill, title: "More chill", symbol: "leaf.fill")]
        case .open:
            return [.replace(.fun, title: "Something fun", symbol: "figure.bowling"),
                    .replace(.sweet, title: "Sweet treat", symbol: "birthday.cake.fill"),
                    .replace(.chill, title: "Something chill", symbol: "leaf.fill"),
                    .replace(.dateNight, title: "Date night", symbol: "heart.fill")]
        }
    }

    /// The eight chips the mood sheet opens on (spec §2). Small on purpose —
    /// the field below them is the escape hatch for everything else.
    static let suggestions: [MoodFamily] =
        [.fun, .sweet, .dateNight, .bored, .crazy, .chill, .lateNight, .competitive]
}

// MARK: - Refinement

/// One refinement chip. Data, not a closure, so a test can assert on what a
/// tap WILL do without running the UI.
struct MoodRefinement: Identifiable, Equatable {
    enum Effect: Equatable {
        /// Swap to a different family outright ("More competitive").
        case replace(MoodFamily)
        /// Fold another family's pool into this one ("Add dessert").
        case merge(MoodFamily)
        /// Narrow to a sub-pool ("Ice cream", "Boba").
        case focus(MoodFocus)
    }

    let title: String
    let symbol: String
    let effect: Effect

    var id: String {
        switch effect {
        case .replace(let f): return "replace-\(f.rawValue)"
        case .merge(let f):   return "merge-\(f.rawValue)"
        case .focus(let f):   return "focus-\(f.rawValue)"
        }
    }

    static func replace(_ family: MoodFamily, title: String, symbol: String) -> MoodRefinement {
        MoodRefinement(title: title, symbol: symbol, effect: .replace(family))
    }

    static func merge(_ family: MoodFamily, title: String, symbol: String) -> MoodRefinement {
        MoodRefinement(title: title, symbol: symbol, effect: .merge(family))
    }

    static func focus(_ focus: MoodFocus) -> MoodRefinement {
        MoodRefinement(title: focus.displayName, symbol: focusSymbol(focus), effect: .focus(focus))
    }

    private static func focusSymbol(_ focus: MoodFocus) -> String {
        switch focus {
        case .iceCream: return "snowflake"
        case .boba:     return "cup.and.saucer.fill"
        case .cookies:  return "circle.grid.2x2.fill"
        case .cafe:     return "cup.and.saucer.fill"
        case .dinner:   return "fork.knife"
        case .activity: return "figure.bowling"
        case .dessert:  return "birthday.cake.fill"
        }
    }
}

// MARK: - Intent

/// The structured place intent a mood resolves to — the only thing the search
/// pipeline ever sees.
struct MoodIntent: Equatable {
    /// How sure the resolver is that it understood the mood. `.low` means
    /// nothing in the vocabulary matched, so the search ALSO carries the
    /// user's own words (spec §10) instead of dead-ending.
    enum Confidence: Equatable { case high, low }

    /// The normalized query, kept in memory for the low-confidence text pass.
    /// Never written to the App Group and never logged (hard constraint 6).
    let originalQuery: String
    let family: MoodFamily
    /// Set by a `.focus` refinement — narrows the pool inside the family.
    let focus: MoodFocus?
    /// Families folded in by `.merge` refinements ("Add dessert").
    let merged: [MoodFamily]
    let exclusions: Set<MoodExclusion>
    /// "not too far" — tightens the vicinity screen. The only distance-shaped
    /// constraint MapKit's data can actually honour.
    let prefersClose: Bool
    let confidence: Confidence

    // MARK: Display

    var displayName: String {
        if let focus { return focus.displayName }
        var name = family.displayName
        if merged.contains(.sweet), family != .sweet { name += " + dessert" }
        return name
    }

    var emoji: String { focus?.emoji ?? family.emoji }

    /// What the search field shows while a mood is active. Distinct from a
    /// typed query so `runSearch` can tell the two apart.
    var searchFieldText: String { "\(displayName) \(emoji)" }

    var energyLevel: MoodEnergy { family.energy }

    var foodPreference: MoodFoodPreference {
        if exclusions.contains(.food) || exclusions.contains(.restaurants) { return .exclude }
        return focus == .dinner ? .only : family.foodPreference
    }

    // MARK: Search inputs

    /// POI categories to browse, exclusions already removed.
    var categories: [MKPointOfInterestCategory] {
        var pool = focus?.poiCategories ?? family.poiCategories
        for family in merged { pool += family.poiCategories }
        let blocked = Set(exclusions.flatMap(\.excludedCategories))
        var seen = Set<MKPointOfInterestCategory>()
        return pool.filter { !blocked.contains($0) && seen.insert($0).inserted }
    }

    /// Text-engine terms, exclusions already removed. A low-confidence intent
    /// leads with the user's own words so an unrecognised mood still searches
    /// for what they said.
    var keywords: [String] {
        var terms: [String] = []
        if confidence == .low, !originalQuery.isEmpty { terms.append(originalQuery) }
        terms += focus?.keywords ?? family.keywords
        for family in merged { terms += family.keywords }
        let blockedTerms = exclusions.flatMap(\.excludedNameTerms)
        var seen = Set<String>()
        return terms.filter { term in
            guard seen.insert(term).inserted else { return false }
            // Never issue a query for something the user just excluded.
            guard term != originalQuery else { return true }
            return !blockedTerms.contains { term.contains($0) }
        }
    }

    /// The refinement chips shown under the results. A focused intent offers
    /// its family's siblings so the user can hop sideways, never restart.
    var refinements: [MoodRefinement] {
        family.refinements.filter { refinement in
            if case .focus(let f) = refinement.effect { return f != focus }
            return true
        }
    }

    // MARK: Transforms

    /// The intent after a refinement chip tap.
    func applying(_ refinement: MoodRefinement) -> MoodIntent {
        switch refinement.effect {
        case .replace(let family):
            return MoodIntent(originalQuery: originalQuery, family: family, focus: nil,
                              merged: [], exclusions: exclusions,
                              prefersClose: prefersClose, confidence: .high)
        case .merge(let family):
            guard !merged.contains(family), family != self.family else { return self }
            return MoodIntent(originalQuery: originalQuery, family: self.family, focus: nil,
                              merged: merged + [family], exclusions: exclusions,
                              prefersClose: prefersClose, confidence: confidence)
        case .focus(let focus):
            return MoodIntent(originalQuery: originalQuery, family: family, focus: focus,
                              merged: merged, exclusions: exclusions,
                              prefersClose: prefersClose, confidence: .high)
        }
    }

    /// A plain intent for a suggestion chip tap — no free text involved.
    static func suggestion(_ family: MoodFamily) -> MoodIntent {
        MoodIntent(originalQuery: "", family: family, focus: nil, merged: [],
                   exclusions: [], prefersClose: false, confidence: .high)
    }

    // MARK: Result screening

    /// True when this place contradicts something the user excluded.
    ///
    /// Two signals, because MapKit leaves `pointOfInterestCategory` nil on a
    /// large share of results: the category when there is one, and the place
    /// NAME otherwise. A place that matches neither is kept — the filter
    /// removes what it can prove, it does not guess.
    func excludes(_ item: MKMapItem) -> Bool {
        guard !exclusions.isEmpty else { return false }
        if let category = item.pointOfInterestCategory,
           exclusions.contains(where: { $0.excludedCategories.contains(category) }) {
            return true
        }
        guard let name = item.name?.lowercased(), !name.isEmpty else { return false }
        let tokens = Set(MoodIntentResolver.normalize(name).split(separator: " ").map(String.init))
        for exclusion in exclusions {
            for term in exclusion.excludedNameTerms {
                if term.contains(" ") {
                    if name.contains(term) { return true }
                } else if tokens.contains(term) {
                    return true
                }
            }
        }
        return false
    }

    /// Screened results, in the order they came in.
    func filtered(_ items: [MKMapItem]) -> [MKMapItem] {
        exclusions.isEmpty ? items : items.filter { !excludes($0) }
    }

    /// One short line explaining why this place fits the mood — derived from
    /// its POI category, falling back to the family. Never a paragraph, and
    /// never a claim about data MapKit doesn't vend (hours, price, crowd).
    func note(for item: MKMapItem) -> String? {
        if let category = item.pointOfInterestCategory,
           let note = Self.categoryNote(category) {
            return note
        }
        return Self.familyNote(family, focus: focus)
    }

    private static func categoryNote(_ category: MKPointOfInterestCategory) -> String? {
        if #available(iOS 18.0, *) {
            switch category {
            case .bowling:      return "Competitive, good for a group"
            case .goKart:       return "Fast and competitive"
            case .miniGolf:     return "Low-stakes competition"
            case .rockClimbing: return "Active and competitive"
            case .skatePark, .skating: return "Active, plenty of energy"
            case .tennis, .basketball, .soccer, .volleyball, .baseball:
                return "Competitive, bring a group"
            case .golf:         return "Slow, outdoors, competitive"
            case .swimming:     return "Active, easy to cool off"
            case .hiking:       return "Outside, get some air"
            case .musicVenue:   return "Live music, late energy"
            case .spa:          return "Quiet and low effort"
            default: break
            }
        }
        switch category {
        case .amusementPark: return "High energy, big day out"
        case .movieTheater:  return "Easy plan, no talking required"
        case .museum:        return "Slow wander, plenty to talk about"
        case .aquarium:      return "Slow wander, easy on everyone"
        case .zoo:           return "Outside, easy to stretch out"
        case .theater:       return "A booked plan, worth the trip"
        case .stadium:       return "Big-event energy"
        case .park:          return "Outside, free, easy to reach"
        case .nationalPark:  return "Outside, worth the drive"
        case .beach:         return "Outside, low effort"
        case .campground:    return "Outside, room to spread out"
        case .cafe:          return "Chill, easy to talk"
        case .bakery:        return "Quick sweet stop"
        case .restaurant:    return "Sit down and eat"
        case .nightlife:     return "Lively, good for a late one"
        case .brewery, .winery: return "Drinks with room to sit"
        case .fitnessCenter: return "Active, burn some energy"
        case .library:       return "Quiet, easy to talk"
        default:             return nil
        }
    }

    private static func familyNote(_ family: MoodFamily, focus: MoodFocus?) -> String? {
        if let focus {
            switch focus {
            case .iceCream, .cookies, .dessert: return "Quick sweet stop"
            case .boba, .cafe:                  return "Chill, easy to talk"
            case .dinner:                       return "Sit down and eat"
            case .activity:                     return "Something to do, not just food"
            }
        }
        switch family {
        case .fun:         return "Something to do, not just food"
        case .bored:       return "Kills an hour easily"
        case .sweet:       return "Quick sweet stop"
        case .dateNight:   return "Good for two"
        case .crazy:       return "High energy"
        case .chill:       return "Low-key, easy to talk"
        case .lateNight:   return "A late-night kind of spot"
        case .competitive: return "Something to compete at"
        case .outdoors:    return "Outside, get some air"
        case .food:        return "Somewhere to eat"
        case .drinks:      return "Somewhere for drinks"
        case .open:        return nil
        }
    }
}
