import Foundation
import CoreLocation

/// The payload carried in an iMessage bubble's `MSMessage.url`.
///
/// Encodes only a human-readable spot name and a single coordinate — never
/// route geometry — so the URL stays well under the 5000-char ceiling and uses
/// only the `https`/`file` schemes that Messages permits.
struct TweenState: Equatable {
    enum Kind: String {
        case participant
        case place
    }

    let text: String
    let latitude: Double
    let longitude: Double
    /// Display name of whoever composed this bubble, so the recipient can see
    /// who invited them. Optional so bubbles from older builds still decode.
    let senderName: String?
    /// What the coordinate represents. Older bubbles lacked this field; those
    /// decode as `.participant` only when they are the legacy "I'm in" payload.
    let kind: Kind

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var representsParticipantLocation: Bool {
        kind == .participant
    }

    func encodedURL() -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "tween.app"
        components.path = "/m"
        var items = [
            URLQueryItem(name: "t", value: text),
            URLQueryItem(name: "lat", value: String(latitude)),
            URLQueryItem(name: "lon", value: String(longitude)),
            URLQueryItem(name: "kind", value: kind.rawValue)
        ]
        if let senderName {
            items.append(URLQueryItem(name: "from", value: senderName))
        }
        components.queryItems = items
        guard let url = components.url, url.absoluteString.count <= 5000 else { return nil }
        return url
    }

    init(text: String, latitude: Double, longitude: Double, senderName: String? = nil, kind: Kind? = nil) {
        self.text = text
        self.latitude = latitude
        self.longitude = longitude
        self.senderName = senderName
        self.kind = kind ?? (text == "I'm in" ? .participant : .place)
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
        self.text = t
        self.latitude = lat
        self.longitude = lon
        // Optional — absent on bubbles from builds before this field existed.
        self.senderName = items.first(where: { $0.name == "from" })?.value
        if let rawKind = items.first(where: { $0.name == "kind" })?.value,
           let kind = Kind(rawValue: rawKind) {
            self.kind = kind
        } else {
            self.kind = t == "I'm in" ? .participant : .place
        }
    }
}
