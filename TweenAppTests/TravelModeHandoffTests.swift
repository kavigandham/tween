import XCTest
import MapKit
@testable import TweenApp

/// Pins that a chosen travel mode actually reaches the maps app.
///
/// These exist because a commit claiming "mode now threads through" shipped
/// with `request.transportType = .automobile` untouched — the edit had silently
/// no-opped, and 303 passing tests said nothing, because every existing MapLinks
/// test called the API without a `mode:` argument and so only ever pinned the
/// default. A green suite reported a fix that was not in the binary
/// (audit 2026-08-05).
final class TravelModeHandoffTests: XCTestCase {

    private let coordinate = CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194)

    func testAppleDirectionsModeCoversEveryTravelMode() {
        XCTAssertEqual(SpotDetailCard.appleDirectionsMode(.driving), MKLaunchOptionsDirectionsModeDriving)
        XCTAssertEqual(SpotDetailCard.appleDirectionsMode(.transit), MKLaunchOptionsDirectionsModeTransit)
        XCTAssertEqual(SpotDetailCard.appleDirectionsMode(.walking), MKLaunchOptionsDirectionsModeWalking)
    }

    func testGoogleTravelModeCoversEveryTravelMode() {
        XCTAssertEqual(MapLinks.googleTravelMode(.driving), "driving")
        XCTAssertEqual(MapLinks.googleTravelMode(.transit), "transit")
        XCTAssertEqual(MapLinks.googleTravelMode(.walking), "walking")
    }

    /// Every mode must survive into the app-scheme URL — not just the default.
    func testGoogleAppURLCarriesEachMode() throws {
        for mode in TravelMode.allCases {
            let url = try XCTUnwrap(MapLinks.googleMapsURL(name: "Blue Bottle", coordinate: coordinate, mode: mode))
            XCTAssertTrue(url.absoluteString.contains("directionsmode=\(MapLinks.googleTravelMode(mode))"),
                          "\(mode) missing from \(url.absoluteString)")
        }
    }

    /// The web fallback is the branch taken when Google Maps ISN'T installed.
    /// It dropped the mode and silently emitted driving, so the same tap gave
    /// two different answers depending on what the user had installed.
    func testGoogleWebFallbackCarriesEachMode() throws {
        for mode in TravelMode.allCases {
            let url = try XCTUnwrap(MapLinks.googleMapsWebURL(name: "Blue Bottle", coordinate: coordinate, mode: mode))
            XCTAssertTrue(url.absoluteString.contains("travelmode=\(MapLinks.googleTravelMode(mode))"),
                          "\(mode) missing from \(url.absoluteString)")
        }
    }

    /// A non-driving mode must never map to the driving constant. This is the
    /// assertion that would have failed on the hardcoded `.automobile`.
    func testNonDrivingModesNeverResolveToDriving() {
        for mode in TravelMode.allCases where mode != .driving {
            XCTAssertNotEqual(SpotDetailCard.appleDirectionsMode(mode), MKLaunchOptionsDirectionsModeDriving)
            XCTAssertNotEqual(MapLinks.googleTravelMode(mode), "driving")
            XCTAssertNotEqual(mode.transportType, .automobile,
                              "\(mode).transportType resolves to .automobile — ETA fetches would be drive times")
        }
    }
}
