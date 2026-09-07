import SwiftUI
import MapKit
import CoreLocation
import MessageUI
import Messages
import UIKit
import Combine
import os

// Bottom sheet: search surface + results list (split from OnboardingView.swift — structure plan R2).
extension OnboardingView {
    // MARK: - Bottom sheet

    /// True when the sheet is collapsed to its search-bar-only peek.
    var isMinimalDetent: Bool { selectedSheetDetent == .height(Tokens.Layout.sheetPeekHeight) }

    @ViewBuilder
    var sheetContent: some View {
        // Zero spacing at peek: the collapsed block below must add NOTHING to
        // the header's height — a leftover 12 pt gap made the peek content
        // taller than the peek sheet, SwiftUI centred the overflow, and the
        // search bar rode up under the handle (device report 2026-09-06).
        VStack(spacing: isMinimalDetent ? 0 : Tokens.Spacing.s3) {
            // The persistent search row lives in a FIXED-HEIGHT header
            // exactly one peek tall, centered within it — a constant
            // offset from the sheet's top edge in every phase so it
            // rides the edge on drags instead of teleporting when the
            // detent settles. (A tapped result no longer swaps this
            // surface for an intermediate card: selection goes straight
            // to the full place sheet — one tap, like Apple Maps.)
            collapsedMeetupHeader
                .frame(height: Tokens.Layout.sheetPeekHeight)

            // Everything below the header stays IN the hierarchy at peek,
            // collapsed to zero height and hidden. Removing it (the old
            // `if !isMinimalDetent`) tore the whole chips + results tree down
            // on every peek settle and rebuilt it, cards and all, in one
            // frame on the way back up — a stall at each end of a drag
            // (measured 2026-09-06). Zero height, not just opacity: left at
            // its natural size the hidden stack overflowed the peek sheet and
            // SwiftUI centred the overflow, pushing the search bar half off
            // the top edge.
            // ONE container, not a Group: Group forwards modifiers to each
            // child, so the zero-height frame applied per child and the outer
            // stack still laid spacing between four empty slots.
            VStack(spacing: Tokens.Spacing.s3) {
                if !monitor.isOnline { offlineBanner }
                plannedMeetupBanner
                replyBanner
                mapPanel
            }
            .frame(maxHeight: isMinimalDetent ? 0 : .infinity)
            .clipped()
            .opacity(isMinimalDetent ? 0 : 1)
            // `.clipped()` is drawing-only and opacity 0 does not remove a
            // subtree from hit testing: the chips row keeps its intrinsic
            // height inside the zero frame and overflows, invisibly, up
            // into the header — where a tap meant for the search bar could
            // land on a hidden chip (audit 2026-09-06).
            .allowsHitTesting(!isMinimalDetent)
            .accessibilityHidden(isMinimalDetent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(Tokens.Motion.snappy, value: selectedSheetDetent)
        // Dragging the results down slides the keyboard out with the finger
        // instead of leaving it planted over a resizing sheet.
        .scrollDismissesKeyboard(.interactively)
        .onChange(of: selectedSheetDetent) { _, detent in
            // The sheet is about to animate to the new detent — that motion
            // is not a drag (see the edge tracker's drop-focus rule).
            sheetEdge.expectMotion()
            // Collapsing to the peek pill ends the editing session — holding
            // first responder under a collapsed sheet kept the keyboard (and
            // its re-focus) fighting the drag whenever the field had text.
            if detent == .height(Tokens.Layout.sheetPeekHeight) { searchFocused = false }
        }
        // The banner's plan sheet. Presented from the bottom sheet — which is
        // always on screen — so it works with no spot card open.
        .sheet(item: $planSheet) { planSheetContent($0) }
        // The tour's sheet-layer slice: spotlights the sheet's controls and
        // hosts the target-less cards (welcome, done).
        .overlayPreferenceValue(CoachTargetKey.self) { anchors in
            CoachMarkOverlay(step: tourOverlayStep, layer: .sheet,
                             calloutLayer: tourCalloutLayer, edge: sheetEdge,
                             anchors: anchors, onNext: advanceTour, onSkip: skipTour)
        }
        // Toasts sit ABOVE the tour's dim, or "Couldn't get your location"
        // renders under 55 % black exactly when it matters.
        .overlay(alignment: .bottom) { toastView }
        .sensoryFeedback(trigger: isUserIn) { _, isIn in isIn ? .success : nil }
        .sensoryFeedback(.impact, trigger: pingTick)
        .alert("Your Name", isPresented: $showNamePrompt) {
            TextField("Name", text: $nameDraft)
            Button("Save", action: saveName)
            Button("Cancel", role: .cancel) { pendingNameAction = nil }
        } message: {
            Text("Add your name so friends see who's inviting them.")
        }
    }

    /// The place-search surface below the search bar. What it shows depends on
    /// where the search flow is: suggestions while typing, otherwise chips +
    /// presence (+ result cards once a search is committed).
    @ViewBuilder
    var mapPanel: some View {
        // Cross-fade between the two phases: the old hard identity swap
        // (suggestion list ⟷ chips + result cards) replaced the whole
        // subtree with no transition, which read as a boxy jump whenever a
        // drag or keystroke crossed a state boundary (device feedback).
        Group {
            switch searchState {
            case .suggesting:
                suggestionsList
                    .transition(.opacity)
            case .idle, .results:
                VStack(spacing: Tokens.Spacing.s3) {
                    categoryChips
                    Divider()
                    resultsScroll
                }
                .transition(.opacity)
            }
        }
        .animation(Tokens.Motion.snappy, value: searchState)
    }

    /// Compact completer-driven suggestion rows shown while the user types.
    /// Tapping a row commits that suggestion as a full search.
    var suggestionsList: some View {
        ScrollView {
            // Plain VStack, not Lazy: at most six rows, and a LazyVStack
            // recomputes its visible window against the scroll viewport —
            // which changes on EVERY frame while the sheet is being dragged.
            // That was the drag feeling choppy only once the field had text
            // (device report 2026-08-06); with no text this subtree isn't in
            // the hierarchy at all, which is why an empty bar felt fine.
            VStack(spacing: 0) {
                if completer.results.isEmpty {
                    // Phase-aware empty state (audit W16): the spinner was
                    // shown for EVERY empty result set, so a completer
                    // failure or a no-match query spun forever.
                    HStack(spacing: Tokens.Spacing.s2) {
                        switch completer.phase {
                        case .failed:
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundStyle(Tokens.Palette.textSecondary)
                            Text("Search unavailable — check your connection")
                                .font(Tokens.Typography.footnote)
                                .foregroundStyle(Tokens.Palette.textSecondary)
                        case .resolved:
                            Image(systemName: "magnifyingglass")
                                .foregroundStyle(Tokens.Palette.textSecondary)
                            Text("No nearby matches — try a different name")
                                .font(Tokens.Typography.footnote)
                                .foregroundStyle(Tokens.Palette.textSecondary)
                        case .idle, .searching:
                            ProgressView()
                            Text("Searching nearby...")
                                .font(Tokens.Typography.footnote)
                                .foregroundStyle(Tokens.Palette.textSecondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Tokens.Spacing.s3)
                }
                // Stable string identity: `\.self` on a completion object made
                // SwiftUI re-diff all six rows whenever the completer republished.
                ForEach(Array(completer.results.prefix(6).enumerated()),
                        id: \.offset) { _, completion in
                    Button { selectSuggestion(completion) } label: {
                        SuggestionRow(completion: completion)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Searches for \(completion.title)")
                    Divider()
                }
            }
            .padding(.horizontal)
        }
    }

    /// The map's compact utility cluster. Recenter stays one tap away; lower-
    /// frequency controls live in a labelled menu instead of four equally
    /// prominent buttons competing down the screen edge. VERTICAL, menu on
    /// top: the horizontal pill collided with the centered List/Map toggle
    /// on device (feedback 2026-07-31).
    var topMapToolbar: some View {
        VStack(spacing: 0) {
            mapOptionsButton

            Divider()
                .frame(width: Tokens.Spacing.s6)

            resetMapButton
        }
        .padding(Tokens.Spacing.s1)
        .modifier(TweenGlassControl(shape: Capsule()))
        .coachTarget(.mapToolbar)
        .padding(.top, Tokens.Spacing.s2)
        .padding(.trailing, Tokens.Spacing.s4)
    }

    // The Search-here pill (its tracker, overlay and padding) lives at the
    // bottom of this file as `SheetEdgeTracker` + `SearchHerePillOverlay`.

    var mapOptionsButton: some View {
        Menu {
            Section("Map style") {
                ForEach(MapDisplayStyle.allCases) { style in
                    Button {
                        withAnimation(Tokens.Motion.snappy) {
                            mapDisplayStyle = style
                        }
                    } label: {
                        Label(style.title,
                              systemImage: style == mapDisplayStyle ? "checkmark" : style.icon)
                    }
                }
            }

            Divider()

            Button { activeSheet = .settings } label: {
                Label("Settings", systemImage: "gearshape")
            }

            // Dismiss another selection sheet before presenting the guide;
            // SwiftUI allows one secondary presentation on this hierarchy.
            Button { activeSheet = nil; startTour() } label: {
                Label("Tween guide", systemImage: "info.circle")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(Tokens.Typography.headline)
                .foregroundStyle(Tokens.Palette.textPrimary)
                .frame(width: floatingControlSize, height: floatingControlSize)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Map options")
        .accessibilityValue(mapDisplayStyle.title)
        .accessibilityHint("Shows map style, settings, and help")
    }

    var resetMapButton: some View {
        Button {
            resetMapCamera()
        } label: {
            Image(systemName: "location.viewfinder")
                .font(Tokens.Typography.headline)
                .foregroundStyle(Tokens.Palette.textPrimary)
                .frame(width: floatingControlSize, height: floatingControlSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Recenter map")
        .accessibilityHint("First shows visible places, then returns to your location")
    }

    /// Floating List/Map switch over the map, shown only when there are results
    /// so it stays reachable even when the sheet is collapsed to its peek.
    @ViewBuilder
    var viewModeToggle: some View {
        if isSearchActive && !searchResults.isEmpty {
            Picker("Results view", selection: $searchViewMode) {
                ForEach(SearchViewMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: Tokens.Layout.minTapTarget * 4 + Tokens.Spacing.s6)
            .padding(Tokens.Spacing.s1)
            .modifier(TweenGlassControl(shape: Capsule()))
            .padding(.top, Tokens.Spacing.s2)
            .accessibilityHint("Switches between a list of results and pins on the map")
        }
    }

    /// Top-of-sheet banner when the network drops; search is gated while offline.
    var offlineBanner: some View {
        HStack(spacing: Tokens.Spacing.s2) {
            Image(systemName: "wifi.slash")
            Text("You're offline. Reconnect to find meetup spots.")
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .font(Tokens.Typography.footnote.weight(.medium))
        .foregroundStyle(.white)
        .padding(Tokens.Spacing.s3)
        .frame(maxWidth: .infinity)
        .background(Tokens.Palette.warning, in: RoundedRectangle(cornerRadius: Tokens.Radius.card))
        .padding(.horizontal)
        .accessibilityElement(children: .combine)
    }

    /// A nudge that the other side just shared a spot, shown across both tabs
    /// while the inbound bubble is still fresh.
    @ViewBuilder
    var replyBanner: some View {
        if let lastReplyAt,
           peerCoordinate != nil,
           Date().timeIntervalSince(lastReplyAt) < Self.replyFreshness {
            HStack(spacing: Tokens.Spacing.s2) {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                Text("Your friend replied \(RelativeTime.string(from: lastReplyAt))")
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(Tokens.Typography.footnote.weight(.medium))
            .padding(Tokens.Spacing.s3)
            .background(Tokens.Palette.brand.opacity(0.15), in: RoundedRectangle(cornerRadius: Tokens.Radius.card))
            .padding(.horizontal)
            .accessibilityElement(children: .combine)
        }
    }

}

/// The permanent sheet's MEASURED top edge, in global (screen) coordinates.
///
/// A reference type observed by ONE view — `SearchHerePillOverlay` — rather
/// than a `@State` on `OnboardingView`. The sheet's `onGeometryChange` fires on
/// every frame of a drag (120 Hz on ProMotion), and as `@State` each frame
/// invalidated the entire home screen: the Map with every marker, the group
/// bar and every result card, all inside an animated transaction. Measured
/// with `Self._printChanges()` (2026-09-05): 63 full-body passes for two short
/// drags, every one attributed to the edge. With `@Observable`, SwiftUI
/// re-renders only the view whose body READS `topGlobalY`, and the map screen
/// never does.
@Observable
final class SheetEdgeTracker {
    var topGlobalY: CGFloat?

    /// Until when edge motion is EXPECTED — a detent change or the keyboard
    /// raising the sheet — and must not be read as the user's finger.
    @ObservationIgnored private var expectedMotionUntil = Date.distantPast

    /// Covers the sheet's detent animation (~0.3 s) and the keyboard's
    /// (~0.25 s) with margin.
    func expectMotion(for duration: TimeInterval = 0.7) {
        expectedMotionUntil = Date().addingTimeInterval(duration)
    }

    var isMotionExpected: Bool { Date() < expectedMotionUntil }
}

/// Google/Apple-style re-search affordance: appears once the user pans or
/// zooms far enough from the searched area that the pins no longer describe
/// the viewport; tapping re-runs the search where they're looking, without
/// moving the camera.
///
/// Parks a small gap above the sheet's MEASURED top edge. Detent-constant
/// math can't be trusted here: iOS 26's floating Liquid Glass panel rides
/// higher than `.height(sheetPeekHeight)` implies, which tucked the pill
/// under the glass on device. Both frames are global/screen space, so the
/// offset is exact for any device, text size, detent, or mid-drag position.
struct SearchHerePillOverlay: View {
    let edge: SheetEdgeTracker
    /// Whether the pill should show at all (drift exists AND the sheet isn't
    /// at the full detent, where the list covers the map).
    let isVisible: Bool
    let action: () -> Void

    var body: some View {
        GeometryReader { geo in
            pill
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, bottomPadding(in: geo))
        }
        // The visibility gate flips on the detent (hidden at 0.90); keyed
        // here so a USER drag to/from full can't land the flip in a
        // transaction with no measured-edge change and pop the transition.
        .animation(Tokens.Motion.snappy, value: isVisible)
        // Smooths the pill when the sheet's measured edge lands discretely
        // (detent settle); during a live drag the streaming updates get
        // exponentially smoothed (snappy is an easeOut, re-targeted per
        // tick), so the pill trails the edge slightly and converges.
        .animation(Tokens.Motion.snappy, value: edge.topGlobalY)
    }

    @ViewBuilder
    private var pill: some View {
        if isVisible {
            Button(action: action) {
                // Apple Maps text treatment (sentence case, no glyph) on the
                // system's Liquid Glass chrome (device feedback 2026-07-31:
                // solid slate read as foreign next to the glass sheet).
                Text("Search here")
                    .font(Tokens.Typography.subheadline.weight(.semibold))
                    .foregroundStyle(Tokens.Palette.mapPillText)
                    .padding(.horizontal, Tokens.Spacing.s5)
                    .frame(minHeight: Tokens.Layout.minTapTarget)
            }
            .buttonStyle(.plain)
            .modifier(TweenGlassControl(shape: Capsule()))
            // Plain fade: scale-while-fading fought the measured-edge motion
            // and read as the pill shrinking into nowhere.
            .transition(.opacity)
            .accessibilityHint("Searches again in the area you're looking at")
        }
    }

    private func bottomPadding(in geo: GeometryProxy) -> CGFloat {
        if let sheetTopGlobalY = edge.topGlobalY {
            let mapBottom = geo.frame(in: .global).maxY
            return max(mapBottom - sheetTopGlobalY + Tokens.Spacing.s4, Tokens.Spacing.s4)
        }
        // Pre-measurement fallback (first frame only): peek constant.
        return max(Tokens.Layout.sheetPeekHeight + Tokens.Spacing.s4 - geo.safeAreaInsets.bottom,
                   Tokens.Spacing.s4)
    }
}
