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

    /// The map layer can't be seen under a full-height (opaque) sheet, and a
    /// peek sheet can't fit a card — so the callout lives on the map unless
    /// the sheet is at full height. See `CoachMarkOverlay.calloutLayer`.
    var tourCalloutLayer: CoachLayer {
        selectedSheetDetent == Self.fullDetent ? .sheet : .map
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
            // The tap itself counts (awaitingImIn flips synchronously) — a
            // denied or slow fix must not strand the tour on this step.
            if awaitingImIn || isUserIn { setTourStep(nextAfterJoin) }
        case .coffeeChip:
            if searchState == .results, !isSearchLoading {
                // Nothing nearby (offline, a remote area): skip the card step
                // rather than spotlight a card that doesn't exist.
                setTourStep(displayedItems.isEmpty ? .friends : .openSpot)
            }
        case .openSpot:
            if case .spot = activeSheet { setTourStep(.friends) }
        case .friends:
            if case .friends = activeSheet { setTourStep(.mapControls) }
        default:
            break
        }
    }

    /// After joining: straight to the results if a search is already on
    /// screen (tour restarted from the menu), else to the chip.
    private var nextAfterJoin: TourStep {
        searchState == .results && !displayedItems.isEmpty ? .openSpot : .coffeeChip
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
            case .mapControls:
                searchFocused = false
                selectedSheetDetent = .height(Tokens.Layout.sheetPeekHeight)
            default:
                break
            }
        }
    }
}
