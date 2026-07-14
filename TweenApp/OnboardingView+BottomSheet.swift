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
        VStack(spacing: Tokens.Spacing.s3) {
            // The persistent search row lives in a FIXED-HEIGHT header
            // exactly one peek tall, centered within it — a constant
            // offset from the sheet's top edge in every phase so it
            // rides the edge on drags instead of teleporting when the
            // detent settles. (A tapped result no longer swaps this
            // surface for an intermediate card: selection goes straight
            // to the full place sheet — one tap, like Apple Maps.)
            searchBar
                .frame(height: Tokens.Layout.sheetPeekHeight)

            // Everything else is revealed once the sheet lifts off peek.
            if !isMinimalDetent {
                if !monitor.isOnline { offlineBanner }
                replyBanner
                mapPanel
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(Tokens.Motion.snappy, value: selectedSheetDetent)
        // Dragging the results down slides the keyboard out with the finger
        // instead of leaving it planted over a resizing sheet.
        .scrollDismissesKeyboard(.interactively)
        .onChange(of: selectedSheetDetent) { _, detent in
            // Collapsing to the peek pill ends the editing session — holding
            // first responder under a collapsed sheet kept the keyboard (and
            // its re-focus) fighting the drag whenever the field had text.
            if detent == .height(Tokens.Layout.sheetPeekHeight) { searchFocused = false }
        }
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
            LazyVStack(spacing: 0) {
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
                            Text("No matches — try a different name")
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
                ForEach(completer.results.prefix(6), id: \.self) { completion in
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

    var topTrailingControls: some View {
        VStack(alignment: .trailing, spacing: Tokens.Spacing.s2) {
            infoButton
            settingsButton
            mapStyleButton
            resetMapButton
        }
        .padding(.top, Tokens.Spacing.s2)
        .padding(.trailing, Tokens.Spacing.s4)
    }

    /// Floating control for the Settings sheet (maps-app preference).
    var settingsButton: some View {
        Button { activeSheet = .settings } label: {
            Image(systemName: "gearshape.fill")
                .font(Tokens.Typography.title2)
                .foregroundStyle(Tokens.Palette.brand)
                .frame(width: floatingControlSize, height: floatingControlSize)
                .modifier(TweenGlassControl(shape: Circle()))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Settings")
        .accessibilityHint("Choose which maps app opens directions")
    }


    var mapStyleButton: some View {
        HStack(spacing: Tokens.Spacing.s2) {
            if isMapStylePickerExpanded {
                HStack(spacing: Tokens.Spacing.s2) {
                    ForEach(MapDisplayStyle.allCases) { style in
                        Button {
                            withAnimation(Tokens.Motion.snappy) {
                                mapDisplayStyle = style
                                isMapStylePickerExpanded = false
                            }
                        } label: {
                            mapControlIcon(style.icon, isSelected: style == mapDisplayStyle)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(style.title)
                    }
                }
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }

            Button {
                withAnimation(Tokens.Motion.snappy) {
                    isMapStylePickerExpanded.toggle()
                }
            } label: {
                mapControlIcon(mapDisplayStyle.icon)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Map style")
            .accessibilityValue(mapDisplayStyle.title)
            .accessibilityHint("Shows map style choices")
        }
        .animation(Tokens.Motion.snappy, value: isMapStylePickerExpanded)
    }

    func mapControlIcon(_ systemName: String, isSelected: Bool = false) -> some View {
        Image(systemName: systemName)
            .font(Tokens.Typography.callout)
            .foregroundStyle(isSelected ? .white : Tokens.Palette.brand)
            .frame(width: floatingControlSize, height: floatingControlSize)
            .modifier(TweenGlassControl(
                shape: RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous),
                isSelected: isSelected))
    }


    var resetMapButton: some View {
        Button {
            resetMapCamera()
        } label: {
            Image(systemName: "location.viewfinder")
                .font(Tokens.Typography.callout)
                .foregroundStyle(Tokens.Palette.brand)
                .frame(width: floatingControlSize, height: floatingControlSize)
                .modifier(TweenGlassControl(
                    shape: RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Reset map")
        .accessibilityHint("First shows visible places, then returns to your location")
    }

    /// Floating control to re-show the first-run walkthrough.
    var infoButton: some View {
        // Dismiss any open place sheet first: `.fullScreenCover` and
        // `.sheet(item:)` share this hierarchy, and SwiftUI presents only one —
        // so tapping Help while a sheet is up would otherwise silently no-op.
        Button { activeSheet = nil; showTutorial = true } label: {
            Image(systemName: "info.circle.fill")
                .font(Tokens.Typography.title2)
                .foregroundStyle(Tokens.Palette.brand)
                .frame(width: floatingControlSize, height: floatingControlSize)
                .modifier(TweenGlassControl(shape: Circle()))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Help")
        .accessibilityHint("Shows the welcome walkthrough")
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
