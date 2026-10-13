import SwiftUI
import MapKit
import CoreLocation

// "What's the mood?" — intent-based discovery on top of the existing search
// funnel. Split out of OnboardingView+Search.swift so the mood path is one
// readable unit; it adds NO ranking, NO midpoint math, and NO result UI of
// its own (structure plan R2).
extension OnboardingView {

    // MARK: - Entry

    /// Opens the mood sheet. A mood and a category chip are two answers to the
    /// same question, so opening this drops any active chip — but it leaves
    /// Open Now, the participants, and the camera exactly where they are
    /// (spec §15: never silently reset an unrelated filter).
    func openMoodSheet() {
        // Pro. Free keeps the fair-spot ranking and everyone's travel times —
        // the argument the app is built on. Saying what you're in the mood for
        // is the thing worth paying for (product decision 2026-10-13).
        guard ProEntitlement.isUnlocked else { activeSheet = .paywall; return }
        activeSheet = .mood
    }

    /// Runs a mood the sheet just produced.
    ///
    /// Funnels through the ordinary committed-search path — `searchText` is
    /// set programmatically (so the field explains what's on screen), the
    /// in-flight `searchTask` is cancelled, and `runSearch` routes to the mood
    /// branch. Everything downstream — fairness ranking, map framing, detents,
    /// the Search Here pill — is the code a category chip already runs.
    func startMoodSearch(_ intent: MoodIntent) {
        activeSheet = nil
        selectedCategory = nil
        selectedResult = nil
        moodBroadened = false
        activeMood = intent
        setSearchTextProgrammatically(intent.searchFieldText)
        expandToSearchDetent()
        commitSearch()
    }

    /// A refinement chip under the results. Adjusts the intent in place and
    /// re-runs the same pipeline — the user never starts over (spec §8).
    func applyMoodRefinement(_ refinement: MoodRefinement) {
        guard let current = activeMood else { return }
        MoodAnalytics.refinementSelected(refinement)
        startMoodSearch(current.applying(refinement))
    }

    /// Re-runs one of the "try something similar" moods offered by the empty
    /// state, keeping whatever the user excluded.
    func retryMood(as family: MoodFamily) {
        let exclusions = activeMood?.exclusions ?? []
        let prefersClose = activeMood?.prefersClose ?? false
        startMoodSearch(MoodIntent(originalQuery: "", family: family, focus: nil,
                                   merged: [], exclusions: exclusions,
                                   prefersClose: prefersClose, confidence: .high))
    }

    /// Clears the mood from the header's ×.
    ///
    /// Goes through `clearSearch` (one owner for emptying the result surface)
    /// but RESTORES Open Now afterwards: that chip is a filter the user set
    /// separately, and this button says "clear the mood", not "clear my
    /// filters" (spec §15 — never silently reset an unrelated filter).
    func dismissMood() {
        let openNowWasOn = openNowOnly
        clearSearch()
        openNowOnly = openNowWasOn
    }

    /// Leaves mood mode. Called from `dismissMood` (via `clearSearch`) and
    /// from every path that invalidates the current result set (typing, a
    /// category chip, Clear).
    /// Bumping the sequence is what makes a mood search already in flight
    /// unable to publish into the surface it just left.
    func clearMood() {
        guard activeMood != nil else { return }
        activeMood = nil
        moodBroadened = false
        moodSequence.invalidate()
    }

    // MARK: - Search

    /// Resolves a mood into places around the CURRENT search region.
    ///
    /// Two rungs, mirroring the typed-search rescue ladder: the meetup
    /// corridor first, then the surrounding metro when the corridor has
    /// nothing (spec §11 — broaden before admitting defeat). Deliberately
    /// bounded at the metro box, never global: an unbounded fallback is what
    /// once answered a query with a name match 8,300 miles away.
    @MainActor
    func resolveMoodPlaces(_ intent: MoodIntent,
                           region: MKCoordinateRegion) async -> (items: [MKMapItem], broadened: Bool) {
        // "not too far" is the one distance constraint MapKit's data can
        // actually honour — it tightens the screen rather than pretending to
        // know anything about the drive.
        let baseSanity = Self.vicinitySanityMeters(for: region)
        let sanity = intent.prefersClose ? max(baseSanity / 2, 15_000) : baseSanity

        let local = await MoodPlaceSearch.places(
            for: intent, region: region, regionRequired: true,
            sanityMeters: sanity, openNowOnly: openNowOnly)
        if !local.isEmpty { return (local, false) }

        guard !Task.isCancelled else { return ([], false) }

        // Broadened rung: the metro box, region-hinted rather than
        // region-required, same intent.
        let metro = MKCoordinateRegion(
            center: region.center,
            span: MKCoordinateSpan(latitudeDelta: Self.metroSpanDegrees,
                                   longitudeDelta: Self.metroSpanDegrees))
        let wider = await MoodPlaceSearch.places(
            for: intent, region: metro, regionRequired: false,
            sanityMeters: Self.metroSanityMeters, openNowOnly: openNowOnly)
        return (wider, !wider.isEmpty)
    }

    /// The mood branch of `runSearch`. Takes a ticket before the first request
    /// and refuses to publish on anything but the newest one, so switching
    /// moods quickly can never land an older result set over a newer search
    /// (spec §16).
    @MainActor
    func runMoodSearch(_ intent: MoodIntent, region: MKCoordinateRegion, reframeMap: Bool) async {
        let ticket = moodSequence.issue()
        let resolved = await resolveMoodPlaces(intent, region: region)
        guard !Task.isCancelled, moodSequence.isCurrent(ticket), activeMood == intent else { return }
        moodBroadened = resolved.broadened
        MoodAnalytics.resultsLoaded(intent, count: resolved.items.count, broadened: resolved.broadened)
        await presentSearchResults(items: resolved.items, region: region,
                                   rewrittenQuery: nil, reframeMap: reframeMap)
    }

    // MARK: - Results header

    /// "The mood: Something fun 🎳" plus the refinement chips, shown above the
    /// ordinary result cards. Nothing here replaces the result UI — the cards
    /// below are the same `ResultCard` every search renders.
    @ViewBuilder
    var moodResultsHeader: some View {
        if let mood = activeMood {
            VStack(alignment: .leading, spacing: Tokens.Spacing.s3) {
                HStack(spacing: Tokens.Spacing.s2) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("The mood: \(mood.displayName) \(mood.emoji)")
                            .font(Tokens.Typography.headline)
                            .foregroundStyle(Tokens.Palette.textPrimary)
                            .lineLimit(2)
                        if moodBroadened {
                            // Honest: these came from a wider box than the
                            // meetup corridor, so say so rather than letting
                            // them pose as fair midpoint results.
                            Text("Nothing in the middle — widened the search")
                                .font(Tokens.Typography.caption)
                                .foregroundStyle(Tokens.Palette.textSecondary)
                        }
                    }
                    Spacer(minLength: 0)
                    Button { dismissMood() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(Tokens.Typography.title2)
                            .foregroundStyle(Tokens.Palette.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear the mood")
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Tokens.Spacing.s2) {
                        ForEach(mood.refinements) { refinement in
                            Button { applyMoodRefinement(refinement) } label: {
                                Label(refinement.title, systemImage: refinement.symbol)
                                    .font(Tokens.Typography.subheadline)
                                    .padding(.horizontal, Tokens.Spacing.s4)
                                    .frame(minHeight: Tokens.Layout.minTapTarget)
                                    .background(Tokens.Palette.surfaceSecondary, in: Capsule())
                                    .foregroundStyle(Tokens.Palette.textPrimary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint("Adjusts the mood and searches again")
                        }
                    }
                    // Bleeds to the sheet edge like every other chip rail,
                    // then pads itself back — the list around it already
                    // carries horizontal padding.
                    .padding(.horizontal, Tokens.Spacing.s4)
                }
                .padding(.horizontal, -Tokens.Spacing.s4)
            }
            .padding(.top, Tokens.Spacing.s1)
            .sensoryFeedback(.selection, trigger: mood)
        }
    }

    /// Mood-aware empty state. "No results" is a dead end; the search has
    /// already broadened to the metro by the time this renders, so the useful
    /// move left is a nearby vibe (spec §11).
    @ViewBuilder
    func moodEmptyState(_ mood: MoodIntent) -> some View {
        VStack(spacing: Tokens.Spacing.s4) {
            ContentUnavailableView(
                "Nothing perfect for that vibe nearby",
                systemImage: "sparkles",
                description: Text(openNowOnly
                    ? "Try turning off Open Now, or try something similar."
                    : "Try something similar."))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Tokens.Spacing.s2) {
                    ForEach(Self.similarMoods(to: mood), id: \.self) { family in
                        Button { retryMood(as: family) } label: {
                            Text("\(family.emoji) \(family.displayName)")
                                .font(Tokens.Typography.subheadline)
                                .padding(.horizontal, Tokens.Spacing.s4)
                                .frame(minHeight: Tokens.Layout.minTapTarget)
                                .background(Tokens.Palette.surfaceSecondary, in: Capsule())
                                .foregroundStyle(Tokens.Palette.textPrimary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Searches for \(family.displayName.lowercased()) instead")
                    }
                }
                .padding(.horizontal, Tokens.Spacing.s4)
            }
            .padding(.horizontal, -Tokens.Spacing.s4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Tokens.Spacing.s3)
    }

    /// Three neighbouring vibes to offer when a mood comes back empty — never
    /// the one that just failed, and never one the user's exclusions rule out.
    static func similarMoods(to mood: MoodIntent) -> [MoodFamily] {
        let neighbours: [MoodFamily]
        switch mood.family {
        case .fun, .bored, .crazy:  neighbours = [.chill, .sweet, .food, .competitive]
        case .competitive:          neighbours = [.fun, .chill, .sweet, .outdoors]
        case .sweet:                neighbours = [.chill, .food, .fun, .drinks]
        case .dateNight:            neighbours = [.food, .sweet, .chill, .outdoors]
        case .chill:                neighbours = [.sweet, .outdoors, .food, .fun]
        case .lateNight:            neighbours = [.food, .drinks, .sweet, .fun]
        case .outdoors:             neighbours = [.chill, .fun, .sweet, .food]
        case .food, .drinks:        neighbours = [.sweet, .chill, .fun, .outdoors]
        case .open:                 neighbours = [.fun, .sweet, .chill, .food]
        }
        let blocked = mood.exclusions
        return neighbours.filter { family in
            guard family != mood.family else { return false }
            switch family {
            case .food:   return !blocked.contains(.food) && !blocked.contains(.restaurants)
            case .sweet:  return !blocked.contains(.dessert)
            case .drinks: return !blocked.contains(.bars)
            case .outdoors: return !blocked.contains(.outdoors)
            default: return true
            }
        }
        .prefix(3)
        .map { $0 }
    }
}
