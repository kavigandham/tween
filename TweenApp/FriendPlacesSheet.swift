import SwiftUI
import MapKit

/// One friend's saved addresses — Home, Work, anywhere.
///
/// Replaces the single "home base" swipe action, which allowed exactly one
/// address per person and hid it behind a gesture. A friend realistically
/// starts from different places depending on the day, and picking a fair
/// midpoint from the wrong one is worse than not knowing at all.
///
/// Ping lives here too, so tapping a friend opens one place that does
/// everything rather than firing an irreversible action on a single tap.
struct FriendPlacesSheet: View {
    let friend: TweenFriend
    var searchRegion: MKCoordinateRegion
    var resolvePlace: (String, MKCoordinateRegion) async -> [MKMapItem]
    var onPing: () -> Void = {}
    /// Fired after any write so the presenter can reload its roster copy —
    /// a stale parent copy is what made the group editor's addresses inert
    /// (audit 2026-08-04).
    var onChanged: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @State private var places: [FriendPlace]
    @State private var addingLabel: String?

    init(friend: TweenFriend,
         searchRegion: MKCoordinateRegion,
         resolvePlace: @escaping (String, MKCoordinateRegion) async -> [MKMapItem],
         onPing: @escaping () -> Void = {},
         onChanged: @escaping () -> Void = {}) {
        self.friend = friend
        self.searchRegion = searchRegion
        self.resolvePlace = resolvePlace
        self.onPing = onPing
        self.onChanged = onChanged
        _places = State(initialValue: friend.places)
    }

    /// Presets not already used, so "Home" disappears once Home is set.
    private var availablePresets: [String] {
        FriendPlace.presetLabels.filter { preset in
            !places.contains { $0.label.compare(preset, options: .caseInsensitive) == .orderedSame }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if places.isEmpty {
                        Text("No addresses yet. Add where \(friend.name) usually starts from and Tween can find fair spots without them sharing live location.")
                            .font(Tokens.Typography.subheadline)
                            .foregroundStyle(Tokens.Palette.textSecondary)
                    }
                    ForEach(places) { place in
                        HStack(spacing: Tokens.Spacing.s3) {
                            TweenRowIcon(systemImage: icon(for: place.label),
                                         color: Tokens.Palette.brand, size: 36)
                            Text(place.label)
                                .foregroundStyle(Tokens.Palette.textPrimary)
                            Spacer(minLength: 0)
                            if place.id == FriendPlace.preferred(from: places)?.id, places.count > 1 {
                                Text("Used for groups")
                                    .font(Tokens.Typography.caption)
                                    .foregroundStyle(Tokens.Palette.textTertiary)
                            }
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { remove(place) } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                } header: {
                    Text("Addresses")
                } footer: {
                    if places.count > 1 {
                        Text("Groups use Home when there is one, otherwise the first address.")
                    }
                }

                Section {
                    ForEach(availablePresets, id: \.self) { preset in
                        Button { addingLabel = preset } label: {
                            Label("Add \(preset)", systemImage: "plus.circle.fill")
                        }
                    }
                    Button { addingLabel = "" } label: {
                        Label("Add another address", systemImage: "plus.circle")
                    }
                }

                if friend.handle != nil {
                    Section {
                        Button { onPing(); dismiss() } label: {
                            Label("Ping \(friend.name)", systemImage: "paperplane.fill")
                        }
                    }
                }
            }
            .navigationTitle(friend.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: Binding(
                get: { addingLabel.map { PendingLabel(text: $0) } },
                set: { addingLabel = $0?.text }
            )) { pending in
                AddPointSheet(
                    title: pending.text.isEmpty
                        ? "\(friend.name)'s address"
                        : "\(friend.name)'s \(pending.text.lowercased())",
                    prompt: "Search for the place",
                    region: searchRegion,
                    resolvePlace: resolvePlace) { point in
                        // An unlabelled add takes the place's own name, so a
                        // row is never just "Address".
                        let label = pending.text.isEmpty ? point.name : pending.text
                        FriendRoster.addPlace(id: friend.id, label: label,
                                              coordinate: point.coordinate)
                        places = FriendRoster.load()
                            .first { $0.id == friend.id }?.places ?? places
                        onChanged()
                        addingLabel = nil
                    }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func remove(_ place: FriendPlace) {
        FriendRoster.removePlace(id: friend.id, placeID: place.id)
        places = FriendRoster.load().first { $0.id == friend.id }?.places ?? []
        onChanged()
    }

    private func icon(for label: String) -> String {
        switch label.lowercased() {
        case "home":   return "house.fill"
        case "work":   return "briefcase.fill"
        case "school": return "book.fill"
        case "gym":    return "figure.run"
        default:       return "mappin"
        }
    }
}

/// `.sheet(item:)` needs an Identifiable; a bare String label isn't one, and an
/// empty string is a legitimate value here ("add another address").
private struct PendingLabel: Identifiable {
    let text: String
    var id: String { text }
}
