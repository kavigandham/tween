import Foundation

/// A one-tap search shortcut for a common meetup category.
///
/// Each case maps to the natural-language query handed to `MKLocalSearch` and an
/// SF Symbol shown in its capsule chip. Styling is literal for now — design
/// tokens arrive in a later phase.
enum CategoryPreset: String, CaseIterable, Identifiable {
    case coffee
    case food
    case drinks
    case gas
    case parks
    case movies
    case fitness

    var id: String { rawValue }

    /// The natural-language term passed to `MKLocalSearch`.
    var searchQuery: String {
        switch self {
        case .coffee:  return "Coffee"
        case .food:    return "Restaurants"
        case .drinks:  return "Bars"
        case .gas:     return "Gas Stations"
        case .parks:   return "Parks"
        case .movies:  return "Movie Theaters"
        case .fitness: return "Gyms"
        }
    }

    /// Short label shown on the chip.
    var title: String {
        switch self {
        case .coffee:  return "Coffee"
        case .food:    return "Food"
        case .drinks:  return "Drinks"
        case .gas:     return "Gas"
        case .parks:   return "Parks"
        case .movies:  return "Movies"
        case .fitness: return "Fitness"
        }
    }

    /// SF Symbol name for the chip's icon.
    var icon: String {
        switch self {
        case .coffee:  return "cup.and.saucer.fill"
        case .food:    return "fork.knife"
        case .drinks:  return "wineglass.fill"
        case .gas:     return "fuelpump.fill"
        case .parks:   return "tree.fill"
        case .movies:  return "film.fill"
        case .fitness: return "dumbbell.fill"
        }
    }
}
