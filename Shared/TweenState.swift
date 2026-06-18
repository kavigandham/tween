import Foundation
import CoreLocation

/// The payload carried in an iMessage bubble's `MSMessage.url`.
///
/// Encodes only a human-readable spot name and a single coordinate — never
/// route geometry — so the URL stays well under the 5000-char ceiling and uses
/// only the `https`/`file` schemes that Messages permits.
struct TweenState: Equatable {
    let text: String
    let latitude: Double
    let longitude: Double

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    func encodedURL() -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "tween.app"
        components.path = "/m"
        components.queryItems = [
            URLQueryItem(name: "t", value: text),
            URLQueryItem(name: "lat", value: String(latitude)),
            URLQueryItem(name: "lon", value: String(longitude))
        ]
        guard let url = components.url, url.absoluteString.count <= 5000 else { return nil }
        return url
    }

    init(text: String, latitude: Double, longitude: Double) {
        self.text = text; self.latitude = latitude; self.longitude = longitude
    }

    init?(url: URL) {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              c.scheme == "https" || c.scheme == "file",
              let items = c.queryItems,
              let t = items.first(where: { $0.name == "t" })?.value,
              let lat = items.first(where: { $0.name == "lat" })?.value.flatMap(Double.init),
              let lon = items.first(where: { $0.name == "lon" })?.value.flatMap(Double.init),
              url.absoluteString.count <= 5000
        else { return nil }
        self.text = t; self.latitude = lat; self.longitude = lon
    }
}
