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
    let onAdd: (Participant) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var completer = SearchCompleter()
    @State private var adding = false

    var body: some View {
        NavigationStack {
            List {
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
            .onChange(of: query) { _, q in completer.debouncedUpdate(query: q, region: region) }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func pick(_ completion: MKLocalSearchCompletion) {
        adding = true
        // @MainActor: onAdd mutates OnboardingView @State and dismiss() drives
        // presentation — both must run on the main actor, not off the bare Task.
        Task { @MainActor in
            let query = completion.subtitle.isEmpty
                ? completion.title : "\(completion.title), \(completion.subtitle)"
            let items = await resolvePlace(query, region)
            if let item = items.first {
                onAdd(Participant.manual(label: item.name ?? completion.title,
                                         coordinate: item.placemark.coordinate))
            }
            dismiss()
        }
    }
}

#Preview {
    OnboardingView()
}
