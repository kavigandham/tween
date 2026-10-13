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

    /// A tap inside the spotlight: performs exactly the step's action. The
    /// real control never sees the touch, so a result card's Send, Call or
    /// Directions can't pull the user out mid-tour.
    func tourTargetTapped(_ target: CoachTarget) {
        switch target {
        case .imInButton:
            guard !isUserIn, !awaitingImIn, provider.status != .requesting else { return }
            imIn()
        case .coffeeChip:
            // selectCategory TOGGLES — a second tap mid-search would cancel it.
            if selectedCategory == .coffee {
                guard !isSearchLoading, searchState != .results else { return }
                // A Coffee tap that never became a search (it was offline):
                // clear it so this tap runs it again instead of toggling off.
                selectedCategory = nil
            }
            selectCategory(.coffee)
        case .firstResultCard:
            if let first = displayedItems.first { selectedResult = first }
        case .sendToChat, .friendsButton, .addFriend, .mapToolbar:
            // Informational, or no longer part of the tour: the card's own
            // button moves on. The targets themselves stay declared because
            // the controls still mark themselves — they are simply never
            // spotlit now that the tour ends at the place sheet.
            break
        }
    }

    /// What the card says while the step's action runs.
    var tourBusyText: String? {
        switch tourStep {
        case .imIn:
            return (awaitingImIn || provider.status == .requesting) ? "Finding you…" : nil
        case .coffeeChip:
            // Only while a search is actually running — a tap that couldn't
            // start one (offline) left a spinner that never ended (audit
            // 2026-09-11).
            return isSearchLoading ? "Finding fair spots…" : nil
        default:
            return nil
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
            setTourStep(afterTheDemo)
        case .pro:
            // "Not now".
            setTourStep(.done)
        case .done:
            finishTour()
        default:
            break
        }
    }

    /// The card's second action — the Pro pitch.
    func tourSecondaryAction() {
        if tourStep == .pro { activeSheet = .paywall }
    }

    /// Where the tour goes once the demonstration is finished — one Pro
    /// card, unless Pro is already owned.
    ///
    /// The tour was TWELVE steps until 2026-10-13 and it walked the user
    /// through every screen in the app: the chat illustration, the Friends
    /// sheet, the map toolbar, saving a Home. People skipped it, which meant
    /// they skipped the part that actually matters. What survives is the
    /// demonstration — join, search, see the fair spots, open one, send it —
    /// because that IS the product, and you cannot understand Tween by
    /// reading about it. Everything cut was a label pointing at a control the
    /// user can find on their own (product decision 2026-10-13).
    private var afterTheDemo: TourStep {
        ProEntitlement.isUnlocked ? .done : .pro
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
                setTourStep(afterTheDemo)
            }
        case .coffeeChip:
            if searchState == .results, !isSearchLoading {
                // Nothing nearby (offline, a remote area): skip the card step
                // rather than spotlight a card that doesn't exist.
                setTourStep(displayedItems.isEmpty ? afterTheDemo : .openSpot)
            } else if !monitor.isOnline || !hasSearchAnchor {
                setTourStep(afterTheDemo)
            }
        case .openSpot:
            if case .spot = activeSheet { setTourStep(.spotSheet) }
        case .spotSheet:
            // Closed by the X or a swipe instead of the card's button: the
            // explanation was on screen, so carry on.
            if activeSheet == nil { setTourStep(afterTheDemo) }
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
              manualParticipants.isEmpty,
              let me = savedCoordinate else { return }
        let friend = Participant.manual(label: Self.demoFriendName,
                                        coordinate: Self.demoFriendCoordinate(from: me))
        tourDemoFriendID = friend.id
        withAnimation(Tokens.Motion.spring) {
            manualParticipants.append(friend)
        }
        frameUserContext()
        // Results already on screen (tour restarted from the menu): rank
        // them against Sam now, the way addManualPoint does, so the cards
        // show both times before the copy promises them.
        if !searchResults.isEmpty {
            searchTask?.cancel()
            isSearchLoading = false
            searchTask = Task { @MainActor in await rerankCurrentResults() }
        }
    }

    /// Whether the cards may talk about Sam: Sam is on the map, or will be
    /// (nobody else is in and the user has no points of their own). With a
    /// real friend or a denied location the copy says "your friend".
    var tourMentionsDemoFriend: Bool {
        tourDemoFriendID != nil
            || (peerCoordinate == nil && additionalParticipants.isEmpty && manualParticipants.isEmpty)
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
        guard monitor.isOnline, hasSearchAnchor else { return afterTheDemo }
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
            case .pro:
                // The place sheet's dismiss restores peek; bring the panel
                // back up so the card has room to render.
                if isMinimalDetent { selectedSheetDetent = .fraction(0.45) }
                searchFocused = false
            default:
                break
            }
        }
    }
}
