import Foundation
import CoreLocation
import MapKit

enum MapLinks {
    /// Google's URL vocabulary for a travel mode. Apple's side uses
    /// `MKLaunchOptionsDirectionsMode*` instead, so the mapping lives at each
    /// call rather than on `TravelMode` itself.
    /// The MKLaunchOptions directions-mode constant for a planned mode.
    /// Lives in Shared (not SpotDetailCard) so the EXTENSION's "Open in Maps"
    /// can use it too — it hardcoded driving long after the host app was
    /// mode-aware, so the same bubble showed a walking ETA and then launched
    /// driving directions when tapped (audit 2026-08-05).
    static func appleDirectionsMode(_ mode: TravelMode) -> String {
        switch mode {
        case .driving: return MKLaunchOptionsDirectionsModeDriving
        case .transit: return MKLaunchOptionsDirectionsModeTransit
        case .walking: return MKLaunchOptionsDirectionsModeWalking
        }
    }

    static func googleTravelMode(_ mode: TravelMode) -> String {
        switch mode {
        case .driving: return "driving"
        case .transit: return "transit"
        case .walking: return "walking"
        }
    }

    static func appleMapsURL(name: String, coordinate: CLLocationCoordinate2D) -> URL? {
        // https so more clients auto-linkify it in the plain-text SMS body.
        var components = URLComponents(string: "https://maps.apple.com/")
        components?.queryItems = [
            URLQueryItem(name: "ll", value: coordinatePair(coordinate)),
            URLQueryItem(name: "q", value: name)
        ]
        return components?.url
    }

    /// Google Maps app scheme — directions straight to the spot in the
    /// caller's travel mode. Only works when the app is installed; callers fall
    /// back to `googleMapsWebURL`.
    ///
    /// `mode` defaults to driving so the message-body links (which have no
    /// per-recipient mode to speak of) are unchanged.
    static func googleMapsURL(name: String, coordinate: CLLocationCoordinate2D,
                              mode: TravelMode = .driving) -> URL? {
        var components = URLComponents()
        components.scheme = "comgooglemaps"
        components.host = ""
        // daddr + directionsmode ONLY — mixing in a `q` search param can flip
        // Google Maps into search mode instead of routing.
        components.queryItems = [
            URLQueryItem(name: "daddr", value: coordinatePair(coordinate)),
            URLQueryItem(name: "directionsmode", value: googleTravelMode(mode))
        ]
        return components.url
    }

    /// Google's official Maps URLs form (`/maps/dir/?api=1`) — a universal
    /// link, so a device WITH Google Maps opens the app and one without opens
    /// the web version. Works for any recipient, no app required.
    static func googleMapsWebURL(name: String, coordinate: CLLocationCoordinate2D,
                                 mode: TravelMode = .driving) -> URL? {
        var components = URLComponents(string: "https://www.google.com/maps/dir/")
        components?.queryItems = [
            URLQueryItem(name: "api", value: "1"),
            URLQueryItem(name: "destination", value: coordinatePair(coordinate)),
            URLQueryItem(name: "travelmode", value: googleTravelMode(mode))
        ]
        return components?.url
    }

    /// Trampoline for the Messages extension: iMessage extensions are not
    /// permitted to open URLs to other apps — `extensionContext.open` launches
    /// the CONTAINING app no matter what URL it's handed (which is exactly how
    /// "Open in Google Maps" ended up opening Tween — device feedback). The
    /// extension opens THIS deep link instead; the host app decodes it and
    /// immediately hands off to Google Maps (app scheme, web fallback).
    static func googleMapsHandoffURL(name: String, coordinate: CLLocationCoordinate2D) -> URL? {
        var components = URLComponents()
        components.scheme = "tween"
        components.host = "maps"
        components.queryItems = [
            URLQueryItem(name: "provider", value: "google"),
            URLQueryItem(name: "lat", value: String(coordinate.latitude)),
            URLQueryItem(name: "lon", value: String(coordinate.longitude)),
            URLQueryItem(name: "name", value: name)
        ]
        return components.url
    }

    /// Decodes a `tween://maps` handoff back into (name, coordinate).
    static func decodeHandoff(_ url: URL) -> (name: String, coordinate: CLLocationCoordinate2D)? {
        guard url.scheme == "tween", url.host == "maps",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let lat = items.first(where: { $0.name == "lat" })?.value.flatMap(Double.init),
              let lon = items.first(where: { $0.name == "lon" })?.value.flatMap(Double.init)
        else { return nil }
        let name = items.first(where: { $0.name == "name" })?.value ?? "Meetup spot"
        return (name, CLLocationCoordinate2D(latitude: lat, longitude: lon))
    }

    private static func coordinatePair(_ coordinate: CLLocationCoordinate2D) -> String {
        "\(coordinate.latitude),\(coordinate.longitude)"
    }
}
