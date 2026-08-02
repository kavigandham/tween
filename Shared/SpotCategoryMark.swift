import SwiftUI

/// The category mark for a place: an SF Symbol plus one of Apple's system
/// colours, in the vivid-filled-circle language Maps uses on every list row.
///
/// Why derive this from the NAME rather than a real category: a proposal
/// travels as `MSMessage.url`, which is capped at 5000 chars and carries
/// coordinates + spot name only (hard constraint 2). No `MKPointOfInterest`
/// category survives the trip, so the receiving side has the name and nothing
/// else. Keyword matching on the name is the honest best available signal —
/// and it's enough to tell a coffee shop from a gas station at a glance, which
/// is the whole job of the mark.
///
/// This replaced a cropped `MKMapSnapshotter` thumbnail on the compact card
/// that rendered a sliced-off fragment of a city label ("Franci") — it carried
/// no information about *which* place the card was about (product decision
/// 2026-08-02). A real storefront photo would be better still; the only
/// no-API-key route to one is `MKLookAroundSnapshotter`, which needs on-device
/// memory profiling before it can go anywhere near the extension's ~120 MB
/// ceiling.
struct SpotCategoryMark {
    let systemImage: String
    let color: Color

    /// Generic place — Apple's own default pin is red.
    static let fallback = SpotCategoryMark(systemImage: "mappin", color: Color(uiColor: .systemRed))

    /// Matched in order; the first table whose keyword appears in the name
    /// wins, so put narrow terms ahead of broad ones ("ice cream" before
    /// "cream", "sports bar" is a bar not a gym).
    private static let table: [(marker: SpotCategoryMark, keywords: [String])] = [
        (SpotCategoryMark(systemImage: "cup.and.saucer.fill", color: Color(uiColor: .systemBrown)),
         ["coffee", "café", "cafe", "espresso", "roaster", "roasting", "starbucks",
          "dunkin", "peet", "philz", "blue bottle", "caribou", "tim horton",
          "boba", "tea house", "teahouse", "bubble tea"]),

        (SpotCategoryMark(systemImage: "wineglass.fill", color: Color(uiColor: .systemPurple)),
         ["bar", "pub", "brewery", "brewing", "taproom", "tavern", "lounge",
          "cocktail", "winery", "distillery", "saloon"]),

        (SpotCategoryMark(systemImage: "birthday.cake.fill", color: Color(uiColor: .systemPink)),
         ["bakery", "patisserie", "donut", "doughnut", "ice cream", "creamery",
          "gelato", "frozen yogurt", "froyo", "cupcake", "dessert"]),

        (SpotCategoryMark(systemImage: "fork.knife", color: Color(uiColor: .systemOrange)),
         ["restaurant", "kitchen", "grill", "chicken", "pizza", "pizzeria",
          "burger", "taco", "taqueria", "bbq", "barbecue", "sushi", "ramen",
          "noodle", "deli", "diner", "bistro", "steakhouse", "buffet", "eatery",
          "mcdonald", "chipotle", "wendy", "chick-fil-a", "panera", "subway",
          "five guys", "shake shack", "popeyes", "kfc", "panda express",
          "cava", "sweetgreen", "hangry"]),

        (SpotCategoryMark(systemImage: "fuelpump.fill", color: Color(uiColor: .systemBlue)),
         ["gas", "fuel", "shell", "exxon", "chevron", "mobil", "sunoco", "bp ",
          "citgo", "wawa", "sheetz", "quiktrip", "racetrac", "charging",
          "supercharger"]),

        (SpotCategoryMark(systemImage: "figure.run", color: Color(uiColor: .systemGreen)),
         ["gym", "fitness", "yoga", "pilates", "crossfit", "pickleball",
          "tennis", "basketball", "soccer", "climbing", "bouldering",
          "swim", "athletic", "recreation", "rec center", "dinkers"]),

        (SpotCategoryMark(systemImage: "tree.fill", color: Color(uiColor: .systemGreen)),
         ["park", "trail", "garden", "lake", "beach", "preserve", "greenway",
          "playground", "arboretum"]),

        (SpotCategoryMark(systemImage: "book.fill", color: Color(uiColor: .systemIndigo)),
         ["library", "bookstore", "books", "study", "campus", "university",
          "college", "school"]),

        (SpotCategoryMark(systemImage: "bag.fill", color: Color(uiColor: .systemYellow)),
         ["mall", "market", "grocery", "walmart", "target", "costco", "kroger",
          "safeway", "trader joe", "whole foods", "aldi", "publix", "wegmans",
          "shopping", "outlet", "store"]),

        (SpotCategoryMark(systemImage: "popcorn.fill", color: Color(uiColor: .systemPink)),
         ["cinema", "theater", "theatre", "movie", "amc", "regal", "imax",
          "bowling", "arcade"]),

        (SpotCategoryMark(systemImage: "bed.double.fill", color: Color(uiColor: .systemIndigo)),
         ["hotel", "motel", "inn", "resort", "lodge", "hostel"]),

        (SpotCategoryMark(systemImage: "airplane", color: Color(uiColor: .systemBlue)),
         ["airport", "terminal"]),

        (SpotCategoryMark(systemImage: "cross.fill", color: Color(uiColor: .systemRed)),
         ["hospital", "clinic", "urgent care", "pharmacy", "cvs", "walgreens",
          "medical"]),
    ]

    static func forName(_ name: String) -> SpotCategoryMark {
        let haystack = name.lowercased()
        for entry in table where entry.keywords.contains(where: haystack.contains) {
            return entry.marker
        }
        return fallback
    }
}
