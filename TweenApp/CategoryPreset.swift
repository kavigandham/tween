import Foundation
import MapKit

/// A one-tap search shortcut for a common meetup category.
///
/// Chips are CATEGORY browses, not text searches: Apple Maps' own category
/// buttons run on `MKPointOfInterestCategory` filters, and MapKit's text
/// engine has no concept for phrases like "Study Spots" (the Study chip
/// returned nothing — device feedback). Each case therefore carries the POI
/// categories the chip means; `searchQuery` remains the label shown in the
/// search field, and `mapKitQuery` is a term the text engine DOES understand,
/// used only as the sparse-area fallback.
enum CategoryPreset: String, CaseIterable, Identifiable {
    case coffee
    case food
    case gas
    case study
    case groceries
    case dessert
    case drinks
    case parks

    var id: String { rawValue }

    /// Shown in the search field while the chip is active (display only).
    var searchQuery: String {
        switch self {
        case .coffee:  return "Coffee"
        case .food:    return "Restaurants"
        case .gas:     return "Gas Stations"
        case .study:   return "Study Spots"
        case .groceries: return "Grocery Stores"
        case .dessert: return "Dessert"
        case .drinks:  return "Bars"
        case .parks:   return "Parks"
        }
    }

    /// What this chip MEANS in MapKit's POI taxonomy — the primary engine.
    var poiCategories: [MKPointOfInterestCategory] {
        switch self {
        case .coffee:  return [.cafe, .bakery]
        case .food:    return [.restaurant]
        case .gas:     return [.gasStation]
        case .study:   return [.library, .cafe, .university]
        case .groceries: return [.foodMarket]
        case .dessert: return [.bakery, .cafe]
        case .drinks:  return [.nightlife, .brewery, .winery]
        case .parks:   return [.park, .nationalPark]
        }
    }

    /// Fallback term for the TEXT engine when the POI request comes back empty
    /// (sparse areas) — a concept MapKit actually knows, unlike "Study Spots".
    var mapKitQuery: String {
        switch self {
        case .coffee:  return "coffee shop"
        case .food:    return "restaurant"
        case .gas:     return "gas station"
        case .study:   return "library"
        case .groceries: return "grocery store"
        case .dessert: return "dessert"
        case .drinks:  return "bar"
        case .parks:   return "park"
        }
    }

    /// Short label shown on the chip.
    var title: String {
        switch self {
        case .coffee:  return "Coffee"
        case .food:    return "Food"
        case .gas:     return "Gas"
        case .study:   return "Study"
        case .groceries: return "Groceries"
        case .dessert: return "Dessert"
        case .drinks:  return "Drinks"
        case .parks:   return "Parks"
        }
    }

    /// SF Symbol name for the chip's icon.
    var icon: String {
        switch self {
        case .coffee:  return "cup.and.saucer.fill"
        case .food:    return "fork.knife"
        case .gas:     return "fuelpump.fill"
        case .study:   return "book.fill"
        case .groceries: return "cart.fill"
        case .dessert: return "birthday.cake.fill"
        case .drinks:  return "wineglass.fill"
        case .parks:   return "tree.fill"
        }
    }
}
