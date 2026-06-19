import Foundation

/// A one-tap search shortcut for a common meetup category.
///
/// Each case maps to the natural-language query handed to `MKLocalSearch` and an
/// SF Symbol shown in its capsule chip.
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

    /// The natural-language term passed to `MKLocalSearch`.
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
