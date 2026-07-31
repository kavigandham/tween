import Foundation
import MapKit

/// Routes category-shaped TYPED queries through the POI-category engine the
/// chips already use.
///
/// Typing "tennis courts" hits only the text engine, which returns whatever
/// Apple has as *named* POIs matching the words; the POI-category engine
/// (`MKLocalPointsOfInterestRequest` + `.tennis`) also returns unnamed public
/// courts the text pass misses. The table maps WHOLE queries only — a query
/// that merely contains a category word ("vegan breakfast") must NOT route,
/// or the generic category flood would drown the attribute results the text
/// engine resolves well (probed 2026-07-31).
enum SearchIntent {

    /// POI categories a typed query means, or empty when the query isn't
    /// category-shaped. Callers merge these results WITH the text pass.
    static func poiCategories(for query: String) -> [MKPointOfInterestCategory] {
        let key = normalized(query)
        if let categories = baseTable[key] { return categories }
        if #available(iOS 18.0, *), let categories = modernTable[key] { return categories }
        return []
    }

    private static func normalized(_ query: String) -> String {
        query.lowercased()
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .joined(separator: " ")
    }

    /// Categories available since iOS 13.
    private static let baseTable: [String: [MKPointOfInterestCategory]] = [
        "coffee": [.cafe, .bakery], "coffee shop": [.cafe, .bakery],
        "coffee shops": [.cafe, .bakery], "cafe": [.cafe], "cafes": [.cafe],
        "café": [.cafe],
        "restaurant": [.restaurant], "restaurants": [.restaurant],
        "food": [.restaurant], "eats": [.restaurant],
        "bar": [.nightlife], "bars": [.nightlife], "drinks": [.nightlife],
        "nightlife": [.nightlife],
        "brewery": [.brewery], "breweries": [.brewery],
        "winery": [.winery], "wineries": [.winery],
        "bakery": [.bakery], "bakeries": [.bakery],
        "dessert": [.bakery, .cafe], "desserts": [.bakery, .cafe],
        "ice cream": [.bakery, .cafe],
        "grocery": [.foodMarket], "groceries": [.foodMarket],
        "grocery store": [.foodMarket], "grocery stores": [.foodMarket],
        "supermarket": [.foodMarket], "supermarkets": [.foodMarket],
        "convenience store": [.foodMarket], "convenience stores": [.foodMarket],
        "corner store": [.foodMarket],
        "gas": [.gasStation], "gas station": [.gasStation],
        "gas stations": [.gasStation],
        "ev charger": [.evCharger], "ev chargers": [.evCharger],
        "ev charging": [.evCharger], "charging station": [.evCharger],
        "charging stations": [.evCharger],
        "park": [.park, .nationalPark], "parks": [.park, .nationalPark],
        "playground": [.park], "playgrounds": [.park],
        "beach": [.beach], "beaches": [.beach],
        "campground": [.campground], "camping": [.campground],
        "gym": [.fitnessCenter], "gyms": [.fitnessCenter],
        "workout": [.fitnessCenter], "fitness": [.fitnessCenter],
        "library": [.library], "libraries": [.library],
        "study": [.library, .cafe, .university],
        "study spot": [.library, .cafe, .university],
        "study spots": [.library, .cafe, .university],
        "school": [.school], "schools": [.school],
        "university": [.university], "college": [.university],
        "pharmacy": [.pharmacy], "pharmacies": [.pharmacy],
        "drug store": [.pharmacy], "drugstore": [.pharmacy],
        "hospital": [.hospital], "urgent care": [.hospital], "er": [.hospital],
        "atm": [.atm, .bank], "atms": [.atm, .bank],
        "bank": [.bank], "banks": [.bank],
        "movie": [.movieTheater], "movies": [.movieTheater],
        "movie theater": [.movieTheater], "movie theaters": [.movieTheater],
        "cinema": [.movieTheater],
        "museum": [.museum], "museums": [.museum],
        "zoo": [.zoo], "aquarium": [.aquarium],
        "amusement park": [.amusementPark],
        "theater": [.theater], "theatre": [.theater],
        "stadium": [.stadium],
        "hotel": [.hotel], "hotels": [.hotel],
        "laundry": [.laundry], "laundromat": [.laundry],
        "post office": [.postOffice],
        "car rental": [.carRental],
    ]

    /// Categories added in iOS 18 (sports, activities, services).
    @available(iOS 18.0, *)
    private static let modernTable: [String: [MKPointOfInterestCategory]] = [
        "tennis": [.tennis], "tennis court": [.tennis],
        "tennis courts": [.tennis],
        "basketball": [.basketball], "basketball court": [.basketball],
        "basketball courts": [.basketball], "hoops": [.basketball],
        "golf": [.golf], "golf course": [.golf], "golf courses": [.golf],
        "mini golf": [.miniGolf], "minigolf": [.miniGolf],
        "putt putt": [.miniGolf],
        "bowling": [.bowling], "bowling alley": [.bowling],
        "bowling alleys": [.bowling],
        "swimming": [.swimming], "swimming pool": [.swimming],
        "swimming pools": [.swimming],
        "hike": [.hiking], "hikes": [.hiking], "hiking": [.hiking],
        "trail": [.hiking], "trails": [.hiking],
        "hiking trail": [.hiking], "hiking trails": [.hiking],
        "skate park": [.skatePark], "skatepark": [.skatePark],
        "skating": [.skating], "ice skating": [.skating],
        "roller skating": [.skating],
        "climbing": [.rockClimbing, .fitnessCenter],
        "rock climbing": [.rockClimbing, .fitnessCenter],
        "climbing gym": [.rockClimbing, .fitnessCenter],
        "go kart": [.goKart], "go karts": [.goKart], "gokart": [.goKart],
        "karting": [.goKart], "go karting": [.goKart],
        "soccer": [.soccer], "volleyball": [.volleyball],
        "baseball": [.baseball],
        "fishing": [.fishing], "kayaking": [.kayaking],
        "skiing": [.skiing],
        "spa": [.spa], "spas": [.spa],
        "live music": [.musicVenue], "concert": [.musicVenue],
        "concerts": [.musicVenue], "music venue": [.musicVenue],
        "auto repair": [.automotiveRepair], "mechanic": [.automotiveRepair],
        "salon": [.beauty], "barber": [.beauty], "haircut": [.beauty],
        "vet": [.animalService], "veterinarian": [.animalService],
    ]
}
