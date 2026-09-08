import SwiftUI
import CoreLocation

// The interactive first-run tour's state machine. The overlays themselves
// live in CoachMarks.swift; this is what decides which step is showing and
// when a step is done. Steps the user performs advance from the app's OWN
// state changes (presence, search, sheets) — the tour never fakes a tap.
extension OnboardingView {
    /// The step to draw. Hidden while a secondary sheet (place, Friends,
    /// composer) covers the home screen — the overlays can't reach it, and
    /// the step that opened it has already advanced to the one that shows
    /// once it closes.
    var tourOverlayStep: TourStep? {
        activeSheet == nil ? tourStep : nil
    }

    /// The step a SECONDARY sheet's overlay draws: only while that sheet is
    /// the presented one and the step belongs to it. The home layers show
    /// nothing meanwhile, and the secondary layers show nothing otherwise.
    func tourStep(inside layer: CoachLayer) -> TourStep? {
        guard let step = tourStep, step.layer == layer else { return nil }
        switch (layer, activeSheet) {
        case (.spot, .spot?), (.friends, .friends?): return step
        default: return nil
        }
    }

    /// The map layer can't be seen under a full-height (opaque) sheet, and a
    /// peek sheet can't fit a card — so the callout lives on the map unless
    /// the sheet is at full height. Steps inside a secondary sheet draw
    /// there. See `CoachMarkOverlay.calloutLayer`.
    var tourCalloutLayer: CoachLayer {
        switch tourStep?.layer {
        case .spot?:    return .spot
        case .friends?: return .friends
        default:        return selectedSheetDetent == Self.fullDetent ? .sheet : .map
        }
    }

    /// From the menu's "Tween guide", or a fresh install's first launch.
    func startTour() {
        searchFocused = false
        withAnimation(Tokens.Motion.snappy) {
            selectedSheetDetent = .fraction(0.45)
            tourStep = .welcome
        }
    }

    /// The Start / Next / Finish button on the steps that have one.
    func advanceTour() {
        guard let step = tourStep else { return }
        switch step {
        case .welcome:
            // Ask for location NOW — the card just said why, and Maps asks on
            // open too. Never over the welcome card itself.
            provider.startContinuousAskingIfNeeded()
            seedTourDemoFriendIfPossible()
            // Restarting the tour mid-meetup: skip what's already done.
            setTourStep(isUserIn ? nextAfterJoin : .imIn)
        case .spotSheet:
            // "Back to the map": close the sheet the step explained and move
            // on in the same transaction, so the observer can't race it.
            activeSheet = nil
            setTourStep(.chatDemo)
        case .chatDemo:
            setTourStep(.friends)
        case .friendsSheet:
            activeSheet = nil
            setTourStep(.mapControls)
        case .mapControls:
            setTourStep(ProEntitlement.isUnlocked ? .done : .pro)
        case .pro:
            // "Not now".
            setTourStep(.done)
        case .done:
            finishTour()
        default:
            break
        }
    }

    /// The card's second action: only the Pro step has one.
    func tourSecondaryAction() {
        guard tourStep == .pro else { return }
        activeSheet = .paywall
    }

    func skipTour() { finishTour() }

    func finishTour() {
        OnboardingFlags.hasSeenOnboarding = true
        tourJoinTapped = false
        removeTourDemoFriend()
        withAnimation(Tokens.Motion.snappy) { tourStep = nil }
        // Skipped from the welcome card: the location ask never happened.
        provider.startContinuousAskingIfNeeded()
    }

    /// Called from the home screen's onChange observers for every piece of
    /// state a performed step waits on. Idempotent: it only moves forward,
    /// and only from the step that is actually waiting.
    func tourDidObserveChange() {
        guard let step = tourStep else { return }
        switch step {
        case .imIn:
            // Wait for the JOIN, not the tap: advancing on the tap parked a
            // denied user on "Tap Coffee" with a search that can never run
            // (audit 2026-09-06 — the App Review path). A denied or failed
            // fix skips the search steps instead; the button shows "Finding
            // you…" meanwhile, which is the honest state.
            if awaitingImIn { tourJoinTapped = true }
            if isUserIn {
                seedTourDemoFriendIfPossible()
                setTourStep(nextAfterJoin)
            } else if tourJoinTapped, !awaitingImIn,
                      provider.status == .denied || provider.status == .failed {
                // Only after the user's OWN tap failed. A stream error or a
                // stale denial arriving before any tap must not whisk the
                // "Tap I'm in" card away unpressed (audit 2026-09-08).
                setTourStep(.friends)
            }
        case .coffeeChip:
            if searchState == .results, !isSearchLoading {
                // Nothing nearby (offline, a remote area): skip the card step
                // rather than spotlight a card that doesn't exist.
                setTourStep(displayedItems.isEmpty ? .friends : .openSpot)
            } else if !monitor.isOnline || !hasSearchAnchor {
                setTourStep(.friends)
            }
        case .openSpot:
            if case .spot = activeSheet { setTourStep(.spotSheet) }
        case .spotSheet:
            // Closed by the X or a swipe instead of the card's button: the
            // explanation was on screen, so carry on.
            if activeSheet == nil { setTourStep(.chatDemo) }
        case .friends:
            if case .friends = activeSheet { setTourStep(.friendsSheet) }
        case .friendsSheet:
            if activeSheet == nil { setTourStep(.mapControls) }
        case .pro:
            // Bought from the paywall the step opened: nothing left to pitch.
            if activeSheet == nil, ProEntitlement.isUnlocked { setTourStep(.done) }
        default:
            break
        }
    }

    // MARK: - The demo friend

    /// The tour's stand-in friend, so the search step shows what Tween is
    /// FOR — two people, a midpoint, spots ranked by both travel times —
    /// instead of a search around one person.
    static let demoFriendName = "Sam (demo)"

    /// About twenty minutes' drive at the app's own straight-line driving
    /// speed, north-east of `origin`. Pure so it is unit-tested.
    static func demoFriendCoordinate(from origin: CLLocationCoordinate2D,
                                     minutes: Double = 20,
                                     bearingDegrees: Double = 45) -> CLLocationCoordinate2D {
        let distance = minutes * 60 * TravelMode.driving.fallbackMetresPerSecond
        let earthRadius = 6_371_000.0
        let angular = distance / earthRadius
        let bearing = bearingDegrees * .pi / 180
        let lat1 = origin.latitude * .pi / 180
        let lon1 = origin.longitude * .pi / 180
        let lat2 = asin(sin(lat1) * cos(angular) + cos(lat1) * sin(angular) * cos(bearing))
        let lon2 = lon1 + atan2(sin(bearing) * sin(angular) * cos(lat1),
                                cos(angular) - sin(lat1) * sin(lat2))
        return CLLocationCoordinate2D(latitude: lat2 * 180 / .pi, longitude: lon2 * 180 / .pi)
    }

    /// Adds the demo friend as a LOCAL manual point — the sanctioned
    /// never-broadcast channel (`manualParticipants` is skipped by every send
    /// path and by the App Group poll) — once the user's coordinate is known.
    /// Not when a real friend is already in: they are the better demo.
    func seedTourDemoFriendIfPossible() {
        guard tourStep != nil, tourDemoFriendID == nil,
              peerCoordinate == nil, additionalParticipants.isEmpty,
              let me = savedCoordinate else { return }
        let friend = Participant.manual(label: Self.demoFriendName,
                                        coordinate: Self.demoFriendCoordinate(from: me))
        tourDemoFriendID = friend.id
        withAnimation(Tokens.Motion.spring) {
            manualParticipants.append(friend)
        }
        frameUserContext()
    }

    /// On Finish, Skip, or backgrounding mid-tour: the demo friend must not
    /// outlive the tour (it would keep ranking real searches against Sam).
    func removeTourDemoFriend() {
        guard let id = tourDemoFriendID else { return }
        tourDemoFriendID = nil
        if let friend = manualParticipants.first(where: { $0.id == id }) {
            removeManualPoint(friend)
        }
    }

    /// After joining: straight to the results if a search is already on
    /// screen (tour restarted from the menu), else to the chip — or past
    /// both when a search can't run (offline, no anchor).
    private var nextAfterJoin: TourStep {
        guard monitor.isOnline, hasSearchAnchor else { return .friends }
        return searchState == .results && !displayedItems.isEmpty ? .openSpot : .coffeeChip
    }

    /// Mirrors `canSearch`'s anchor rule: something to search around.
    private var hasSearchAnchor: Bool {
        savedCoordinate != nil || peerCoordinate != nil || !manualParticipants.isEmpty
    }

    /// Moves to `step` and puts the sheet where that step's control is
    /// visible: the half detent for the join/chip steps, peek for the map
    /// controls. Results steps leave the detent to the search flow.
    private func setTourStep(_ step: TourStep) {
        withAnimation(Tokens.Motion.snappy) {
            tourStep = step
            switch step {
            case .imIn, .coffeeChip:
                if isMinimalDetent || selectedSheetDetent == Self.fullDetent {
                    selectedSheetDetent = .fraction(0.45)
                }
                // A stale Coffee selection would make the spotlit tap a
                // DESELECT (selectCategory toggles) — two taps to proceed.
                if step == .coffeeChip, selectedCategory == .coffee { selectedCategory = nil }
            case .openSpot:
                // Full height: at the half detent the first card sits below
                // the fold on small phones, with scrolling disabled.
                selectedSheetDetent = Self.fullDetent
            case .friends:
                // The place sheet's dismiss restores peek, where a pending
                // meetup swaps the header and unmounts the Friends button.
                if isMinimalDetent { selectedSheetDetent = .fraction(0.45) }
            case .mapControls:
                searchFocused = false
                selectedSheetDetent = .height(Tokens.Layout.sheetPeekHeight)
            default:
                break
            }
        }
    }
}
