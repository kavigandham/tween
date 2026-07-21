import SwiftUI
import MapKit
import CoreLocation
import MessageUI
import Messages
import UIKit
import Combine
import os

// Search: text, category chips, ranking funnel (split from OnboardingView.swift — structure plan R2).
extension OnboardingView {
    // MARK: - Search

    /// Every point that participates in the fair-spot comparison.
    var comparisonCoordinates: [CLLocationCoordinate2D] {
        var points = [savedCoordinate, peerCoordinate].compactMap { $0 }
        points.append(contentsOf: additionalParticipants.map(\.coordinate))
        points.append(contentsOf: manualParticipants.map(\.coordinate))
        return points
    }

    /// The visible center Tween is searching around when comparing two or more
    /// people/points.
    var midpointCoordinate: CLLocationCoordinate2D? {
        let points = comparisonCoordinates
        guard points.count >= 2 else { return nil }
        let lats = points.map(\.latitude)
        let lons = points.map(\.longitude)
        return CLLocationCoordinate2D(
            latitude: lats.reduce(0, +) / Double(points.count),
            longitude: lons.reduce(0, +) / Double(points.count))
    }

    /// The region search is biased toward the midpoint when multiple points are
    /// known, otherwise whichever single location we have. A tighter local span
    /// keeps common searches like coffee, food, and gas near the active context.
    var searchRegion: MKCoordinateRegion {
        let points = comparisonCoordinates
        if points.count >= 2 {
            let lats = points.map(\.latitude), lons = points.map(\.longitude)
            let latDelta = max((lats.max()! - lats.min()!) * 1.35, 0.25)
            let lonDelta = max((lons.max()! - lons.min()!) * 1.35, 0.25)
            return MKCoordinateRegion(
                center: midpointCoordinate ?? Self.defaultCenter,
                span: MKCoordinateSpan(latitudeDelta: latDelta, longitudeDelta: lonDelta))
        }

        let center = points.first ?? Self.defaultCenter
        let span = points.isEmpty ? 0.5 : 0.18
        return MKCoordinateRegion(
            center: center,
            span: MKCoordinateSpan(latitudeDelta: span, longitudeDelta: span))
    }

    /// Reacts to each keystroke. An empty field returns to quick chips; anything
    /// else feeds the completer immediately. Full result cards only appear after
    /// Return, a suggestion tap, or a category/shortcut tap.
    func handleQueryChange(_ query: String) {
        // A programmatic commit (suggestion/category) already started its search;
        // don't let the resulting onChange cancel it or revert to suggestions.
        if suppressNextQueryChange {
            suppressNextQueryChange = false
            return
        }
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            searchResults = []
            rankedSpots = []
            isSearchActive = false
            isSearchLoading = false
            searchState = .idle
            completer.update(query: "")
            return
        }
        // New query — drop stale committed results so the map clears while typing.
        searchResults = []
        rankedSpots = []
        isSearchActive = false
        isSearchLoading = false
        searchState = .suggesting
        // Debounced (300 ms) — the completer only fires on the query the user
        // paused on, not every intermediate keystroke. Per
        // docs/ui-research.md §7.
        completer.debouncedUpdate(query: trimmed, region: searchRegion)
    }

    /// Commits a suggestion as a full search.
    /// Programmatic `searchText` assignment with the suppress flag armed
    /// ONLY when the text actually changes. Arming unconditionally left the
    /// flag set when the assignment was a no-op (tapping a completion titled
    /// exactly what you typed) — SwiftUI's onChange never fired, and the
    /// stale flag then swallowed the NEXT real change: the clear-(x)
    /// gesture, leaving ghost results behind an empty field (audit W15).
    func setSearchTextProgrammatically(_ text: String) {
        suppressNextQueryChange = text != searchText
        searchText = text
    }

    func selectSuggestion(_ completion: MKLocalSearchCompletion) {
        setSearchTextProgrammatically(completion.title)
        commitSearch()
    }

    /// Runs the committed search (keyboard "Search", or a tapped suggestion).
    /// Resigns the keyboard so the result cards / pins are visible.
    func commitSearch() {
        searchTask?.cancel()
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSearch(trimmed) else { return }
        searchFocused = false
        expandToSearchDetent()
        isSearchLoading = true

        searchTask = Task { @MainActor in
            await runSearch(trimmed: trimmed, reframeMap: true)
        }
    }

    func focusSearchPanel() {
        expandToSearchDetent()
    }

    func startShortcutSearch(_ shortcut: QuickSpotShortcut) {
        selectedCategory = nil
        setSearchTextProgrammatically(shortcut.query)
        focusSearchPanel()
        commitSearch()
    }

    /// Clears results and returns `false` when there's nothing to search — an
    /// empty query, or offline (the offline banner gates the field). Returns
    /// `true` when a search should proceed.
    func canSearch(_ trimmed: String) -> Bool {
        guard !trimmed.isEmpty, monitor.isOnline else {
            searchResults = []
            rankedSpots = []
            isSearchActive = false
            isSearchLoading = false
            searchState = .idle
            return false
        }
        // No anchor at all → searchRegion would fall back to the center of the
        // continental US and quietly return results in Kansas. A manually-added
        // A→B point is a valid anchor too — otherwise a GPS-denied user doing a
        // pure manual A→B search got nagged for location even though searchRegion
        // already centers on their points (post-push audit). Ask for a fix only
        // when there's truly nothing to anchor on.
        guard savedCoordinate != nil || peerCoordinate != nil || !manualParticipants.isEmpty else {
            searchResults = []
            rankedSpots = []
            isSearchActive = false
            isSearchLoading = false
            searchState = .idle
            pendingLocationAction = { commitSearch() }
            provider.requestOnce()
            showToast(provider.status == .denied
                      ? "Turn on location access in Settings so search knows where to look"
                      : "Getting your location — searching right after")
            return false
        }
        return true
    }

    /// Resolves a query (address or place name) to map items. Shared by
    /// `runSearch` and the "add a place / person" flow so both hit MapKit
    /// identically; returns [] on failure or zero results.
    func resolvePlace(query: String, region: MKCoordinateRegion) async -> [MKMapItem] {
        func search(regionRequired: Bool) async -> [MKMapItem] {
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = query
            request.region = region
            if regionRequired, #available(iOS 18.0, *) {
                request.regionPriority = .required
            }
            return (try? await MKLocalSearch(request: request).start().mapItems) ?? []
        }
        // First pass constrains the search to the meetup area (not just a hint),
        // so a query with no LOCAL name match generalises to the IDEA within the
        // region — like Apple/Google Maps, "unlimited sushi" → nearby sushi,
        // instead of a business literally named "Sushi Unlimited" on the far side
        // of the world (device feedback). A tiny strict result set can still be
        // incomplete for category-style searches, though, so merge the broader
        // region-hint pass until we have enough candidates for ranking.
        let local = await search(regionRequired: true)
        if #available(iOS 18.0, *) {
            let fallback = local.count < Self.rankCap ? await search(regionRequired: false) : []
            return SearchResultMerger.merge(local: local, fallback: fallback, minimumCount: Self.rankCap)
        }
        return SearchResultMerger.deduped(local)
    }

    /// Resolves a category CHIP the way Apple Maps' own category buttons do: an
    /// `MKLocalPointsOfInterestRequest` for the chip's POI categories, strictly
    /// confined to the meetup region — no text relevance to drift off toward a
    /// commercial corridor, and no dependence on the text engine understanding
    /// a phrase like "Study Spots" (device feedback: the Study chip was dead).
    /// Sparse areas fall back to the text engine with a term it DOES know,
    /// still filtered to the chip's categories.
    func resolveCategory(_ preset: CategoryPreset, region: MKCoordinateRegion) async -> [MKMapItem] {
        // POI requests hard-cap their radius (MKPointsOfInterestRequestMaxRadius);
        // a far-apart group's searchRegion exceeds it, which errored the request
        // and silently skipped the category engine. Clamp instead — the widest
        // allowed circle around the midpoint is exactly where fair spots live
        // (post-push audit).
        let halfSpanMeters = max(region.span.latitudeDelta, region.span.longitudeDelta) * 111_000 / 2
        let radius = min(max(halfSpanMeters, 1_000), MKLocalPointsOfInterestRequest.maxRadius)
        let request = MKLocalPointsOfInterestRequest(center: region.center, radius: radius)
        request.pointOfInterestFilter = MKPointOfInterestFilter(including: preset.poiCategories)
        let items = (try? await MKLocalSearch(request: request).start().mapItems) ?? []
        if !items.isEmpty { return SearchResultMerger.deduped(items) }

        let textRequest = MKLocalSearch.Request()
        textRequest.naturalLanguageQuery = preset.mapKitQuery
        textRequest.region = region
        textRequest.resultTypes = .pointOfInterest
        textRequest.pointOfInterestFilter = MKPointOfInterestFilter(including: preset.poiCategories)
        if #available(iOS 18.0, *) {
            textRequest.regionPriority = .required
        }
        let fallback = (try? await MKLocalSearch(request: textRequest).start().mapItems) ?? []
        return SearchResultMerger.deduped(fallback)
    }

    /// The participant set the local fairness ranking compares — you, every live
    /// peer/participant, AND every manually-added point (solo A→B / added
    /// non-app-users). Nil when there's nobody to compare against (need ≥2
    /// points), so the caller skips ranking and shows plain search results.
    /// Manual points make the app useful alone without pinging anyone.
    var searchRankingParticipants: [Participant]? {
        var participants: [Participant] = []
        if let me = savedCoordinate {
            let myName = UserProfile.displayName ?? UserName.fallback
            participants.append(Participant(id: myName, name: myName, coordinate: me))
        }
        if let peer = peerCoordinate {
            participants.append(Participant(id: "peer", name: "Friend", coordinate: peer))
        }
        participants.append(contentsOf: additionalParticipants)
        participants.append(contentsOf: manualParticipants)
        return participants.count >= 2 ? participants : nil
    }

    /// Adds a locally-picked point (solo A→B / a non-app-user) and refreshes the
    /// map + any on-screen ranking. Never sent.
    func addManualPoint(_ point: Participant) {
        manualParticipants.append(point)
        frameUserContext()
        if searchResults.isEmpty, searchRankingParticipants != nil {
            // Nothing to rank yet — auto-find fair spots between the points so the
            // "best spot" ranking activates immediately, instead of adding a point
            // doing nothing until you separately search (device feedback: it should
            // behave like a person joining). The category chips still let you
            // change what's shown.
            startShortcutSearch(Self.suggestedSpot)
        } else {
            // Funnel through searchTask so a rapid add/remove — or a committed
            // search — cancels an in-flight re-rank; otherwise a slower older
            // MKDirections round-trip could finish last and stomp the current
            // ranking (post-push audit).
            searchTask?.cancel()
            // The cancelled search returns before its own `isSearchLoading =
            // false` — clear it here or the spinner hangs (post-push audit).
            isSearchLoading = false
            searchTask = Task { @MainActor in await rerankCurrentResults() }
        }
    }

    func removeManualPoint(_ point: Participant) {
        manualParticipants.removeAll { $0.id == point.id }
        frameUserContext()
        searchTask?.cancel()
        isSearchLoading = false
        searchTask = Task { @MainActor in await rerankCurrentResults() }
    }

    /// Re-ranks the search results already on screen against the current
    /// participant set — used after adding/removing a manual point, no fresh
    /// MapKit round-trip. Clears ranking when there's nobody to compare against.
    @MainActor
    func rerankCurrentResults() async {
        guard let participants = searchRankingParticipants, !searchResults.isEmpty else {
            rankedSpots = []
            return
        }
        // Fill every visible row/pin immediately. Real routes replace these
        // estimates below, but the UI never has a timing-free gap.
        rankedSpots = FairnessRanker.estimatedRankings(
            candidates: searchResults, participants: participants)
        let cap = participants.count >= 3
            ? FairnessRanker.recommendedCap(for: participants.count)
            : Self.rankCap
        // Same hard between-people cut as runSearch — adding/removing a point
        // reshapes the corridor, so re-filter against the NEW participant set.
        let candidates = SpotVicinity.filter(searchResults, participants: participants, minimumCount: 3)
        let routed = await FairnessRanker.rank(
            candidates: candidates, participants: participants, cap: cap)
        // A newer search/re-rank may have superseded this one mid-flight.
        guard !Task.isCancelled else { return }
        rankedSpots = FairnessRanker.completeRankings(
            routed: routed,
            allCandidates: searchResults,
            participants: participants)
    }

    /// Straight-line distance from you to a manual point, for the route chips.
    func manualPointDistance(_ point: Participant) -> String? {
        guard let me = savedCoordinate else { return nil }
        return ABDistanceLabel.formatDistance(from: me, to: point.coordinate)
    }

    /// Runs `MKLocalSearch`, surfaces raw hits immediately, then ranks the same
    /// hits by fairness whenever there's someone/somewhere to compare against
    /// (a live peer OR a manually-added point). Committed searches (Return,
    /// suggestion, chip, shortcut) may reframe the map.
    @MainActor
    func runSearch(trimmed: String, reframeMap: Bool) async {
        guard monitor.isOnline else {
            isSearchLoading = false
            searchResults = []
            rankedSpots = []
            searchState = .idle
            return
        }

        // A chip tap is a CATEGORY browse, not a text search — route it through
        // the POI-category engine (how Apple Maps' own category buttons work).
        // "Study Spots" means nothing to the text engine, which is why the
        // Study chip found nothing (device feedback).
        let items: [MKMapItem]
        if let preset = selectedCategory, trimmed == preset.searchQuery {
            items = await resolveCategory(preset, region: searchRegion)
        } else {
            items = await resolvePlace(query: trimmed, region: searchRegion)
        }
        guard !Task.isCancelled else { return }

        rankedSpots = []
        searchResults = items
        isSearchActive = true
        isSearchLoading = false
        searchState = .results
        if reframeMap {
            frameSearchResults()
        }

        // Rank fair spots whenever there's at least one other point to compare
        // against — a live peer OR a manually-added place/person (solo A→B).
        // The old code gated on a peer coordinate, which is why the app did
        // nothing useful alone (device feedback).
        if !items.isEmpty, let participants = searchRankingParticipants {
            // Publish a complete estimated set before awaiting MapKit. This
            // keeps participant times present from the first rendered row and
            // gives a fast pin tap the same timing model as a list tap.
            rankedSpots = FairnessRanker.estimatedRankings(
                candidates: items, participants: participants)
            let cap = participants.count >= 3
                ? FairnessRanker.recommendedCap(for: participants.count)
                : Self.rankCap
            // Hard between-people cut BEFORE ranking (device feedback: spots
            // must actually sit between the group, not in whatever commercial
            // corridor MapKit's relevance drifted to). The cut trims the RANKED
            // pool only. Anything it drops (a typed search's one specific far
            // place) keeps a straight-line ETA estimate; a wholly-far pool
            // passes through unfiltered rather than emptying the list
            // (SpotVicinity relaxes ×1.5/×2.5, then gives up).
            let candidates = SpotVicinity.filter(items, participants: participants, minimumCount: 3)
            let routed = await FairnessRanker.rank(
                candidates: candidates, participants: participants, cap: cap)
            guard !Task.isCancelled else { return }
            rankedSpots = FairnessRanker.completeRankings(
                routed: routed,
                allCandidates: items,
                participants: participants)
            if reframeMap {
                frameSearchResults()
            }
        }

        guard reframeMap else { return }

        // Always zoom to fit the results together with both participants, in
        // either view mode, so the camera is never stale once the sheet moves.
        frameResultsWithParticipants()

        switch searchViewMode {
        case .list:
            // Results arrived — expand to full so the cards fill the screen
            // (the framed map becomes the backdrop, visible on drag-down).
            withAnimation(Tokens.Motion.snappy) { selectedSheetDetent = .fraction(0.90) }
        case .map:
            // Keep the sheet at its peek so the freshly framed pins stay visible.
            withAnimation(Tokens.Motion.snappy) {
                selectedSheetDetent = .height(Tokens.Layout.sheetPeekHeight)
            }
        }
    }

    func clearSearch() {
        searchTask?.cancel()
        searchText = ""
        searchResults = []
        rankedSpots = []
        isSearchActive = false
        isSearchLoading = false
        searchState = .idle
        completer.update(query: "")
        selectedCategory = nil
        selectedResult = nil
        searchViewMode = .list
        searchFocused = false
    }

    /// Toggles a preset chip. Re-tapping the active chip clears the search;
    /// otherwise the preset commits straight to results (skipping suggestions,
    /// since a category is already a complete query).
    func selectCategory(_ preset: CategoryPreset) {
        if selectedCategory == preset {
            clearSearch()
        } else {
            selectedCategory = preset
            setSearchTextProgrammatically(preset.searchQuery)
            expandToSearchDetent()
            commitSearch()
        }
    }

}
