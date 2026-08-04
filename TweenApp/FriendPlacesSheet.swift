import SwiftUI
import MapKit

/// One friend's saved addresses — Home, Work, anywhere.
///
/// Replaces the single "home base" swipe action, which allowed exactly one
/// address per person and hid it behind a gesture. A friend realistically
/// starts from different places depending on the day, and picking a fair
/// midpoint from the wrong one is worse than not knowing at all.
///
/// The list is a plain content view, not a sheet, so it can be PUSHED from the
/// group editor as well as presented as a sheet from the friend row. Two
/// competing address editors is how the group editor ended up with one that
/// appended instead of replacing (audit 2026-08-04).
struct FriendPlacesList: View {
    let friend: TweenFriend
    var searchRegion: MKCoordinateRegion
    var resolvePlace: (String, MKCoordinateRegion) async -> [MKMapItem]
    /// Pro gates SAVING an address, not opening this list: ping is free, and a
    /// locked user tapping a friend should see what Pro adds rather than a wall.
    var proUnlocked: Bool = true
    /// nil hides the ping row — the group editor's push doesn't want it.
    var onPing: (() -> Void)?
    /// Called when a locked user asks to add an address.
    var onUpgrade: (() -> Void)?
    /// Fired after any write so the presenter can reload its roster copy —
    /// a stale parent copy is what made the group editor's addresses inert
    /// (audit 2026-08-04).
    var onChanged: () -> Void = {}

    @State private var places: [FriendPlace]
    @State private var addingLabel: String?

    init(friend: TweenFriend,
         searchRegion: MKCoordinateRegion,
         resolvePlace: @escaping (String, MKCoordinateRegion) async -> [MKMapItem],
         proUnlocked: Bool = true,
         onPing: (() -> Void)? = nil,
         onUpgrade: (() -> Void)? = nil,
         onChanged: @escaping () -> Void = {}) {
        self.friend = friend
        self.searchRegion = searchRegion
        self.resolvePlace = resolvePlace
        self.proUnlocked = proUnlocked
        self.onPing = onPing
        self.onUpgrade = onUpgrade
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
        List {
            addressSection
            addSection
            pingSection
        }
        .navigationTitle(friend.name)
        .navigationBarTitleDisplayMode(.inline)
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

    private var addressSection: some View {
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
    }

    @ViewBuilder
    private var addSection: some View {
        Section {
            if proUnlocked {
                ForEach(availablePresets, id: \.self) { preset in
                    Button { beginAdding(preset) } label: {
                        Label("Add \(preset)", systemImage: "plus.circle.fill")
                    }
                }
                Button { beginAdding("") } label: {
                    Label("Add another address", systemImage: "plus.circle")
                }
            } else if let onUpgrade {
                Button(action: onUpgrade) {
                    Label("Save addresses with Tween Pro", systemImage: "sparkles")
                }
            }
        } footer: {
            if !proUnlocked {
                Text("Pro remembers where friends start from, so a group finds fair spots without anyone sharing live location.")
            }
        }
    }

    @ViewBuilder
    private var pingSection: some View {
        if let onPing, friend.handle != nil {
            Section {
                Button(action: onPing) {
                    Label("Ping \(friend.name)", systemImage: "paperplane.fill")
                }
            }
        }
    }

    /// Ignores a second tap landing inside the presentation animation. Changing
    /// `.sheet(item:)`'s id mid-present is the dismiss-then-re-present that
    /// drops silently on iOS 26.
    private func beginAdding(_ label: String) {
        guard addingLabel == nil else { return }
        addingLabel = label
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

/// `FriendPlacesList` as the friend row's sheet.
///
/// Ping and Upgrade DISMISS first and hand the action back to the presenter,
/// which runs it from the sheet's `onDismiss`. Running either inline meant
/// presenting the composer (or paywall) by re-pointing the very `.sheet(item:)`
/// that puts this sheet on screen, and then `dismiss()` overwrote it with nil —
/// the composer never appeared and nothing said why (audit 2026-08-04).
struct FriendPlacesSheet: View {
    let friend: TweenFriend
    var searchRegion: MKCoordinateRegion
    var resolvePlace: (String, MKCoordinateRegion) async -> [MKMapItem]
    var proUnlocked: Bool = true
    /// Park the ping; the presenter fires it once this sheet is gone.
    var onPing: () -> Void = {}
    /// Park the upgrade prompt, same contract.
    var onUpgrade: () -> Void = {}
    var onChanged: () -> Void = {}

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            FriendPlacesList(
                friend: friend,
                searchRegion: searchRegion,
                resolvePlace: resolvePlace,
                proUnlocked: proUnlocked,
                onPing: { dismiss(); onPing() },
                onUpgrade: { dismiss(); onUpgrade() },
                onChanged: onChanged)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

/// `.sheet(item:)` needs an Identifiable; a bare String label isn't one, and an
/// empty string is a legitimate value here ("add another address").
private struct PendingLabel: Identifiable {
    let text: String
    var id: String { text }
}
