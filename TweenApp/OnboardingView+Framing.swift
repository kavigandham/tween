import SwiftUI
import MapKit
import CoreLocation
import MessageUI
import Messages
import UIKit
import Combine
import os

// Camera framing + geometry (split from OnboardingView.swift — structure plan R2).
extension OnboardingView {
    // MARK: - Geometry

    func reframe() {
        if let agreedMeetup, agreedMeetup.kind == .place {
            logger.debug("Map reframe centered on agreed meetup")
            withAnimation(Tokens.Motion.gentle) {
                position = Self.placeCameraPosition(for: agreedMeetup.coordinate)
            }
            return
        }

        var coords = [savedCoordinate, peerCoordinate].compactMap { $0 }
        coords.append(contentsOf: additionalParticipants.map(\.coordinate))
        coords.append(contentsOf: manualParticipants.map(\.coordinate))
        guard !coords.isEmpty else { return }
        logger.debug("Map reframe triggered for \(coords.count, privacy: .public) coordinate(s)")
        withAnimation(Tokens.Motion.gentle) { position = Self.cameraPosition(for: coords) }
    }

    func resetMapCamera() {
        let hasSearchContext = selectedResult != nil || (isSearchActive && !displayedItems.isEmpty)
        if hasSearchContext && !resetNextTapReturnsToUser {
            resetNextTapReturnsToUser = true
            frameVisibleSearchContext()
            return
        }

        resetNextTapReturnsToUser = false
        selectedResult = nil
        frameUserContext()
    }

    func frameVisibleSearchContext() {
        var coords = [savedCoordinate, peerCoordinate].compactMap { $0 }
        coords.append(contentsOf: additionalParticipants.map(\.coordinate))
        coords.append(contentsOf: manualParticipants.map(\.coordinate))

        if let selectedResult {
            coords.append(selectedResult.placemark.coordinate)
        } else {
            coords.append(contentsOf: displayedItems.prefix(Self.rankCap).map(\.placemark.coordinate))
        }

        guard !coords.isEmpty else {
            frameUserContext()
            return
        }

        logger.debug("Manual map reset to search context for \(coords.count, privacy: .public) coordinate(s)")
        withAnimation(Tokens.Motion.gentle) {
            position = Self.cameraPosition(for: coords, padding: 1.35, minSpan: 0.04, bottomBias: 0.25)
        }
    }

    func frameUserContext() {
        if let savedCoordinate {
            // Frame you together with any added A→B points, so adding a place
            // shows both ends rather than snapping tightly onto you.
            let others = manualParticipants.map(\.coordinate) + additionalParticipants.map(\.coordinate)
            if !others.isEmpty {
                withAnimation(Tokens.Motion.gentle) {
                    position = Self.cameraPosition(for: [savedCoordinate] + others, padding: 1.35, minSpan: 0.04)
                }
                return
            }
            logger.debug("Manual map reset to user location")
            withAnimation(Tokens.Motion.gentle) {
                position = .region(MKCoordinateRegion(
                    center: savedCoordinate,
                    span: MKCoordinateSpan(latitudeDelta: 0.018, longitudeDelta: 0.018)))
            }
            return
        }

        var coords = [peerCoordinate].compactMap { $0 }
        coords.append(contentsOf: additionalParticipants.map(\.coordinate))
        coords.append(contentsOf: manualParticipants.map(\.coordinate))
        guard !coords.isEmpty else {
            withAnimation(Tokens.Motion.gentle) {
                position = Self.cameraPosition(for: [Self.defaultCenter])
            }
            return
        }

        logger.debug("Manual map reset to available participant context")
        withAnimation(Tokens.Motion.gentle) {
            position = Self.cameraPosition(for: coords, padding: 1.2, minSpan: 0.04)
        }
    }

    /// Frames the given coordinates with 20% padding on the span. A single point
    /// (or a degenerate cluster) falls back to a comfortable city-level zoom.
    ///
    /// `bottomBias` (0 = none) grows the latitude span and pushes the framed
    /// center south, so the fitted content settles in the upper portion of the
    /// map that the bottom sheet covers nothing of. SwiftUI exposes no live
    /// height for a `.sheet`, so we bias the framing rather than measure it.
    static func cameraPosition(
        for coordinates: [CLLocationCoordinate2D],
        padding: Double = 1.2,
        minSpan: CLLocationDegrees = 0.05,
        bottomBias: CGFloat = 0
    ) -> MapCameraPosition {
        guard let first = coordinates.first else {
            return .region(MKCoordinateRegion(
                center: defaultCenter,
                span: MKCoordinateSpan(latitudeDelta: minSpan, longitudeDelta: minSpan)))
        }

        var minLat = first.latitude, maxLat = first.latitude
        var minLon = first.longitude, maxLon = first.longitude
        for c in coordinates {
            minLat = min(minLat, c.latitude); maxLat = max(maxLat, c.latitude)
            minLon = min(minLon, c.longitude); maxLon = max(maxLon, c.longitude)
        }

        let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2,
                                            longitude: (minLon + maxLon) / 2)
        let degenerate = (maxLat - minLat) < 0.0001 && (maxLon - minLon) < 0.0001
        let baseLatDelta = degenerate ? minSpan : max((maxLat - minLat) * padding, minSpan)
        let lonDelta = degenerate ? minSpan : max((maxLon - minLon) * padding, minSpan)

        let bias = Double(bottomBias)
        let latDelta = baseLatDelta * (1 + bias)
        let biasedCenter = CLLocationCoordinate2D(
            latitude: center.latitude - latDelta * bias * 0.5,
            longitude: center.longitude)

        return .region(MKCoordinateRegion(
            center: biasedCenter,
            span: MKCoordinateSpan(latitudeDelta: latDelta, longitudeDelta: lonDelta)))
    }

    /// Opens concrete places tightly and a touch above center so the bottom
    /// sheet does not hide the pin. Context framing is still available through
    /// reset-map; initial place openings should never land on a midpoint.
    static func placeCameraPosition(
        for coordinate: CLLocationCoordinate2D,
        span: CLLocationDegrees = 0.018,
        bottomBias: CGFloat = 0.18
    ) -> MapCameraPosition {
        let center = CLLocationCoordinate2D(
            latitude: coordinate.latitude - (span * Double(bottomBias)),
            longitude: coordinate.longitude)
        return .region(MKCoordinateRegion(
            center: center,
            span: MKCoordinateSpan(latitudeDelta: span, longitudeDelta: span)))
    }
}
