import SwiftUI
import MapKit
import CoreLocation

/// A lightweight place/address picker for the solo A→B "what's in between" mode
/// and for adding someone who lacks the app. Reuses `SearchCompleter` for
/// typeahead and the caller's `resolvePlace` to turn the pick into a
/// coordinate. Nothing is sent — the result becomes a local `manual:` point.
struct AddPointSheet: View {
    var title = "Add a place or person"
    var prompt = "Address, or where they are"
    let region: MKCoordinateRegion
    let resolvePlace: (String, MKCoordinateRegion) async -> [MKMapItem]
    /// Callers that need the FULL resolved place — a saved Home wants the
    /// formatted address, which `Participant` has no room for — take this
    /// instead of `onAdd`. Exactly one of the two runs, so a sheet can never
    /// report the same pick twice.
    ///
    /// Sits before `onAdd` so a bare trailing closure still binds to `onAdd`
    /// at the three call sites that predate it.
    var onResolve: ((MKMapItem) -> Void)? = nil
    var onAdd: (Participant) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var completer = SearchCompleter()
    @State private var adding = false
    /// Why the last pick didn't resolve. Cleared as soon as the user types
    /// again, so a stale failure never sits over fresh suggestions.
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            List {
                if let failure {
                    Label(failure, systemImage: "exclamationmark.triangle.fill")
                        .font(Tokens.Typography.footnote)
                        .foregroundStyle(Tokens.Palette.warning)
                }
                if adding {
                    HStack(spacing: Tokens.Spacing.s2) { ProgressView(); Text("Adding…") }
                        .foregroundStyle(Tokens.Palette.textSecondary)
                } else if !query.isEmpty && completer.results.isEmpty {
                    Text(completer.phase == .searching ? "Searching…" : "No matches")
                        .foregroundStyle(Tokens.Palette.textSecondary)
                } else {
                    ForEach(completer.results, id: \.self) { completion in
                        Button { pick(completion) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(completion.title)
                                    .foregroundStyle(Tokens.Palette.textPrimary)
                                if !completion.subtitle.isEmpty {
                                    Text(completion.subtitle)
                                        .font(Tokens.Typography.caption)
                                        .foregroundStyle(Tokens.Palette.textSecondary)
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .searchable(text: $query,
                        placement: .navigationBarDrawer(displayMode: .always),
                        prompt: prompt)
            .onChange(of: query) { _, q in
                failure = nil
                completer.debouncedUpdate(query: q, region: region)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        // An OPAQUE background. These are modal task sheets presented ON TOP
        // OF another sheet, and without this they inherit iOS 26 glass over an
        // undimmed parent — the Friends list rendered legibly THROUGH "Your
        // places" and "Where's home?", avatars, addresses and all, which reads
        // as a rendering glitch rather than a material (screenshot audit
        // 2026-10-13). Never stack a light translucent surface on another.
        .presentationBackground(Tokens.Palette.surface)
    }

    private func pick(_ completion: MKLocalSearchCompletion) {
        // A second tap while the first resolve is in flight would run the
        // caller's handler twice — two Homes, two manual points.
        guard !adding else { return }
        adding = true
        failure = nil
        // @MainActor: onAdd mutates OnboardingView @State and dismiss() drives
        // presentation — both must run on the main actor, not off the bare Task.
        Task { @MainActor in
            let query = completion.subtitle.isEmpty
                ? completion.title : "\(completion.title), \(completion.subtitle)"
            let items = await resolvePlace(query, region)
            if let item = items.first {
                if let onResolve {
                    onResolve(item)
                } else {
                    onAdd(Participant.manual(label: item.name ?? completion.title,
                                             coordinate: item.placemark.coordinate))
                }
            } else {
                // The completion couldn't be turned into a place — offline, or
                // a suggestion MapKit can no longer resolve. Say so instead of
                // dismissing as though something was saved (spec §2, geocoding
                // failures are handled, never silent).
                adding = false
                failure = "Couldn't find that address. Try another one."
                return
            }
            dismiss()
        }
    }
}

#Preview {
    OnboardingView()
}
