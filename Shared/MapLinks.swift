import Foundation
import CoreLocation

enum MapLinks {
    static func appleMapsURL(name: String, coordinate: CLLocationCoordinate2D) -> URL? {
        // https so more clients auto-linkify it in the plain-text SMS body.
        var components = URLComponents(string: "https://maps.apple.com/")
        components?.queryItems = [
            URLQueryItem(name: "ll", value: coordinatePair(coordinate)),
            URLQueryItem(name: "q", value: name)
        ]
        return components?.url
    }

    static func googleMapsURL(name: String, coordinate: CLLocationCoordinate2D) -> URL? {
        var components = URLComponents()
        components.scheme = "comgooglemaps"
        components.host = ""
        components.queryItems = [
            URLQueryItem(name: "q", value: name),
            URLQueryItem(name: "center", value: coordinatePair(coordinate)),
            URLQueryItem(name: "zoom", value: "16")
        ]
        return components.url
    }

    static func googleMapsWebURL(name: String, coordinate: CLLocationCoordinate2D) -> URL? {
        var components = URLComponents(string: "https://www.google.com/maps/search/")
        components?.queryItems = [
            URLQueryItem(name: "api", value: "1"),
            URLQueryItem(name: "query", value: "\(name) \(coordinatePair(coordinate))")
        ]
        return components?.url
    }

    private static func coordinatePair(_ coordinate: CLLocationCoordinate2D) -> String {
        "\(coordinate.latitude),\(coordinate.longitude)"
    }
}
