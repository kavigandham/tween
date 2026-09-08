import SwiftUI

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
            // Restarting the tour mid-meetup: skip what's already done.
            setTourStep(isUserIn ? nextAfterJoin : .imIn)
        case .spotSheet:
            // "Back to the map": close the sheet the step explained and move
            // on in the same transaction, so the observer can't race it.
            activeSheet = nil
            setTourStep(.friends)
        case .friendsSheet:
            activeSheet = nil
            setTourStep(.mapControls)
        case .mapControls:
            setTourStep(.done)
        case .done:
            finishTour()
        default:
            break
        }
    }

    func skipTour() { finishTour() }

    func finishTour() {
        OnboardingFlags.hasSeenOnboarding = true
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
            if isUserIn {
                setTourStep(nextAfterJoin)
            } else if !awaitingImIn, provider.status == .denied || provider.status == .failed {
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
            if activeSheet == nil { setTourStep(.friends) }
        case .friends:
            if case .friends = activeSheet { setTourStep(.friendsSheet) }
        case .friendsSheet:
            if activeSheet == nil { setTourStep(.mapControls) }
        default:
            break
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
