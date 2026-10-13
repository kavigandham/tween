import SwiftUI
import MapKit

/// The local user's own saved places — Home in V1.
///
/// The twin of `FriendPlacesList` (a friend's addresses) and deliberately the
/// same shape: one list, an inline address picker, writes that go straight to
/// the store. What it must NOT become is a second address editor with subtly
/// different rules — that divergence is what made "change this friend's
/// address" append a row instead of replacing it (audit 2026-08-04).
///
/// A plain content view rather than a sheet, so it can be pushed as well as
/// presented.
struct MyPlacesList: View {
    var searchRegion: MKCoordinateRegion
    var resolvePlace: (String, MKCoordinateRegion) async -> [MKMapItem]
    /// Fired after any write so the presenter can refresh its own copy —
    /// a stale parent copy is what made the group editor's addresses inert.
    var onChanged: () -> Void = {}

    @State private var home: MyPlace? = MyPlaceStore.home()
    /// Non-nil while the address picker is up. Its value is what we're
    /// setting, so a later Work/School row needs no new state.
    @State private var editing: MyPlaceKind?
    @State private var confirmingRemoval = false
    /// The last write that failed, shown inline. Saving Home is a local
    /// write, so this is rare — but "rare" is not "impossible", and a silent
    /// no-op on a Save button is the worst outcome (spec §20).
    @State private var failure: String?

    var body: some View {
        List {
            homeSection
            if home != nil { removeSection }
        }
        .navigationTitle("Your places")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: Binding(get: { editing }, set: { editing = $0 })) { kind in
            AddPointSheet(
                title: kind == .home ? "Where's home?" : "Where's \(kind.defaultLabel.lowercased())?",
                prompt: "Enter your \(kind.defaultLabel.lowercased()) address",
                region: searchRegion,
                resolvePlace: resolvePlace,
                onResolve: { item in save(item, as: kind) })
        }
        .alert("Remove Home?", isPresented: $confirmingRemoval) {
            Button("Remove", role: .destructive) { removeHome() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your groups and any meetup you've already joined are unaffected — they keep the address they were given at the time.")
        }
        .onAppear { home = MyPlaceStore.home() }
    }

    @ViewBuilder
    private var homeSection: some View {
        Section {
            if let home {
                HStack(spacing: Tokens.Spacing.s3) {
                    TweenRowIcon(systemImage: MyPlaceKind.home.symbol,
                                 color: Tokens.Palette.brand, size: 36)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(home.label)
                            .foregroundStyle(Tokens.Palette.textPrimary)
                        Text(home.address ?? "Saved address")
                            .font(Tokens.Typography.caption)
                            .foregroundStyle(Tokens.Palette.textSecondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Home, \(home.address ?? "saved address")")

                Button { beginEditing(.home) } label: {
                    Label("Change Home", systemImage: "pencil")
                }
            } else {
                Button { beginEditing(.home) } label: {
                    Label("Add Home", systemImage: "plus.circle.fill")
                }
                .accessibilityHint("Saves your home address so joining a Tween is one tap")
            }
            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .font(Tokens.Typography.footnote)
                    .foregroundStyle(Tokens.Palette.warning)
            }
        } header: {
            Text("Home")
        } footer: {
            Text("Your address isn't shown to your friends. Tween only uses it to work out your travel time when you join from home.")
        }
    }

    private var removeSection: some View {
        Section {
            Button(role: .destructive) { confirmingRemoval = true } label: {
                Label("Remove Home", systemImage: "trash")
            }
        }
    }

    /// Ignores a second tap landing inside the presentation animation —
    /// changing `.sheet(item:)`'s id mid-present is the iOS 26 silent drop.
    private func beginEditing(_ kind: MyPlaceKind) {
        guard editing == nil else { return }
        failure = nil
        editing = kind
    }

    private func save(_ item: MKMapItem, as kind: MyPlaceKind) {
        let coordinate = item.placemark.coordinate
        guard CLLocationCoordinate2DIsValid(coordinate) else {
            failure = "That address didn't resolve to a place. Try another one."
            editing = nil
            return
        }
        // The picker's own resolve already geocoded this, so there is nothing
        // to await here: the address string is display sugar, the coordinate
        // is the thing that has to be right.
        let address = item.placemark.cleanLine ?? item.name
        MyPlaceStore.setHome(coordinate: coordinate, address: address)
        home = MyPlaceStore.home()
        failure = nil
        editing = nil
        onChanged()
    }

    private func removeHome() {
        MyPlaceStore.removeHome()
        home = MyPlaceStore.home()
        onChanged()
    }
}

/// `MyPlacesList` presented on its own.
struct MyPlacesSheet: View {
    var searchRegion: MKCoordinateRegion
    var resolvePlace: (String, MKCoordinateRegion) async -> [MKMapItem]
    var onChanged: () -> Void = {}

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            MyPlacesList(searchRegion: searchRegion,
                         resolvePlace: resolvePlace,
                         onChanged: onChanged)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { dismiss() }
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
        .presentationDragIndicator(.visible)
    }
}
