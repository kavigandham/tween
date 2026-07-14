import SwiftUI
import UIKit
import MapKit
import CoreLocation

// Snapshot map section + markers (split from ExpandedView.swift).
extension ExpandedView {
    // MARK: Map

    /// What the static snapshot centers on. The spot you've selected takes
    /// priority — tapping a card recenters the map (redesign: "selection
    /// re-focuses the snapshot") — then a received place or staged draft.
    var snapshotFocus: CLLocationCoordinate2D? {
        selectedSpot?.item?.placemark.coordinate ?? receivedPlaceCoord ?? draft?.coordinate
    }

    @ViewBuilder
    var mapSection: some View {
        if hasMapContent {
            // Snapshotter-only (constraint #1): the cheap static path, no MKMapView.
            TweenMapSnapshotView(
                markers: staticMarkers,
                cornerRadius: 0,
                focusCoordinate: snapshotFocus,
                // The map has its own region above the panel, so only a
                // gentle lift keeps the spot off dead-center (room for the pill).
                focusYOffsetRatio: snapshotFocus != nil ? 0.1 : 0)
        } else {
            ZStack {
                Rectangle().fill(Tokens.Palette.surfaceSecondary)
                VStack(spacing: Tokens.Spacing.s2) {
                    Image(systemName: isWaitingForCoordinates ? "location.circle" : "location.slash")
                        .font(Tokens.Typography.title)
                    Text(isWaitingForCoordinates ? "Waiting for locations" : "Share your location to see the map")
                        .font(Tokens.Typography.footnote)
                }
                .foregroundStyle(Tokens.Palette.textSecondary)
            }
        }
    }

    /// Markers for the snapshot: people, any proposed place, and ranked spots
    /// using the shared pin role system.
    var staticMarkers: [MapMarker] {
        var result: [MapMarker] = []
        if let selfCoord {
            let myId = localParticipantID ?? myName
            let localNeedsRide = LocationCache.loadParticipants().first(where: { $0.matches(id: myId, name: myName) })?.needsRide ?? false
            result.append(MapMarker(coordinate: selfCoord, role: localNeedsRide ? .rideNeeded : (isUserIn ? .selfActive : .selfDot)))
        }
        for participant in otherParticipants {
            result.append(MapMarker(coordinate: participant.coordinate, role: participant.needsRide ? .rideNeeded : .friend))
        }
        // No centroid/midpoint marker (audit F3): the geographic middle isn't a
        // place anyone meets, and on the small extension map it just adds clutter.
        // Exactly ONE gold "the spot" pin. When a proposed place and/or a draft
        // is on the map, the ranked candidates all render as plain results —
        // three identical gold pins gave the user no way to tell which one was
        // the actual proposal.
        let hasHeroSpot = receivedPlaceCoord != nil || draft != nil
        if let receivedPlaceCoord {
            result.append(MapMarker(coordinate: receivedPlaceCoord, role: .fairSpot))
        }
        if let draft {
            result.append(MapMarker(coordinate: draft.coordinate, role: receivedPlaceCoord == nil ? .fairSpot : .result))
        }
        for (index, spot) in rankedSpots.enumerated() {
            if let coordinate = spot.item?.placemark.coordinate {
                let isBest = index == 0 && !hasHeroSpot
                result.append(MapMarker(coordinate: coordinate, role: isBest ? .fairSpot : .result))
            }
        }
        return result
    }

}
