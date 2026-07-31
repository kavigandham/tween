import Foundation
import MapKit

/// Decides when the map camera has drifted far enough from the last-searched
/// area that the results on screen no longer describe what the user is
/// looking at — the moment Apple/Google surface their "Search Here"
/// affordance. Pure geometry so it unit-tests without a map.
enum MapRegionDrift {

    /// True when `visible` has moved or rescaled enough away from `searched`
    /// that a re-search would return meaningfully different places:
    /// - the center moved more than ~35% of the searched span on either axis,
    /// - the user zoomed OUT past ~1.6× (new area revealed at the edges), or
    /// - the user zoomed IN past ~2.2× (a tighter search surfaces places the
    ///   wider pass's result cap swallowed — the "zoom in and more places
    ///   appear" behavior).
    static func isSignificant(from searched: MKCoordinateRegion,
                              to visible: MKCoordinateRegion) -> Bool {
        let latSpan = max(searched.span.latitudeDelta, 0.0001)
        let lonSpan = max(searched.span.longitudeDelta, 0.0001)

        let latShift = abs(visible.center.latitude - searched.center.latitude) / latSpan
        let lonShift = abs(visible.center.longitude - searched.center.longitude) / lonSpan
        if latShift > 0.35 || lonShift > 0.35 { return true }

        let latZoom = visible.span.latitudeDelta / latSpan
        let lonZoom = visible.span.longitudeDelta / lonSpan
        if latZoom > 1.6 || lonZoom > 1.6 { return true }
        if latZoom < 1 / 2.2 && lonZoom < 1 / 2.2 { return true }

        return false
    }
}
