import SwiftUI
import MapKit

/// Create or edit a friend group (Pro): name the group, tick its members.
/// Rows surface each friend's home-base status because the group's whole
/// point is opening it into an instant fair-spot search — a member without a
/// home base just won't land on the map until one is set.
struct GroupEditorSheet: View {
    /// nil = creating a new group.
    var group: FriendGroup?
    /// Members for a group being created from an existing meetup. Used only
    /// when `group` is nil, so the sheet still reads as "New Group".
    var draftMemberIDs: [UUID] = []
    var onSave: (FriendGroup) -> Void = { _ in }
    var onDelete: (UUID) -> Void = { _ in }
    /// Backing out. The parent uses this to undo friends it created just to
    /// populate this editor.
    var onCancel: () -> Void = {}
    /// Fired whenever this sheet writes to FriendRoster (setting an address),
    /// so the parent's copy doesn't go stale while the editor is open.
    var onRosterChanged: () -> Void = {}
    /// Search region + resolver for the inline address picker, so a member's
    /// home base can be set WITHOUT leaving the group you're building.
    var searchRegion: MKCoordinateRegion = MKCoordinateRegion(
        center: .init(latitude: 39.8283, longitude: -98.5795),
        span: .init(latitudeDelta: 0.5, longitudeDelta: 0.5))
    var resolvePlace: (String, MKCoordinateRegion) async -> [MKMapItem] = { _, _ in [] }

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var selected: Set<UUID>
    /// Local copy so a freshly-set address shows immediately in this list —
    /// the parent's `friends` array is a value passed in at present time and
    /// won't reflect a write made from inside this sheet.
    @State private var friends: [TweenFriend]
    /// The member whose addresses we're editing, pushed onto this sheet's own
    /// navigation stack.
    @State private var addressTarget: UUID?

    init(group: FriendGroup? = nil,
         draftMemberIDs: [UUID] = [],
         friends: [TweenFriend],
         onSave: @escaping (FriendGroup) -> Void = { _ in },
         onDelete: @escaping (UUID) -> Void = { _ in },
         onCancel: @escaping () -> Void = {},
         onRosterChanged: @escaping () -> Void = {},
         searchRegion: MKCoordinateRegion = MKCoordinateRegion(
            center: .init(latitude: 39.8283, longitude: -98.5795),
            span: .init(latitudeDelta: 0.5, longitudeDelta: 0.5)),
         resolvePlace: @escaping (String, MKCoordinateRegion) async -> [MKMapItem] = { _, _ in [] }) {
        self.group = group
        self.draftMemberIDs = draftMemberIDs
        self.onSave = onSave
        self.onDelete = onDelete
        self.onCancel = onCancel
        self.onRosterChanged = onRosterChanged
        self.searchRegion = searchRegion
        self.resolvePlace = resolvePlace
        _friends = State(initialValue: friends)
        _name = State(initialValue: group?.name ?? "")
        _selected = State(initialValue: Set(group?.memberIDs ?? draftMemberIDs))
    }

    /// Members that actually resolve against the roster. `selected` alone is
    /// not enough: a draft seeds it from ids whose rows the rollback may have
    /// deleted, which let Save write a silently EMPTY group (audit 2026-08-04).
    private var resolvedMembers: [UUID] {
        friends.filter { selected.contains($0.id) }.map(\.id)
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && !resolvedMembers.isEmpty
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Group name — \"the boys\", \"book club\"…", text: $name)
                        .accessibilityLabel("Group name")
                }
                Section {
                    if friends.isEmpty {
                        Text("Add friends first — a group is made of saved friends.")
                            .foregroundStyle(Tokens.Palette.textSecondary)
                    }
                    ForEach(friends) { friend in
                      HStack(spacing: Tokens.Spacing.s2) {
                        Button { toggle(friend.id) } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(friend.name)
                                        .foregroundStyle(Tokens.Palette.textPrimary)
                                    if let primary = friend.primaryPlace {
                                        Label(primary.label, systemImage: "house.fill")
                                            .font(Tokens.Typography.caption)
                                            .foregroundStyle(Tokens.Palette.textSecondary)
                                    } else {
                                        Text("No address yet")
                                            .font(Tokens.Typography.caption)
                                            .foregroundStyle(Tokens.Palette.textTertiary)
                                    }
                                }
                                Spacer()
                                if selected.contains(friend.id) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(Tokens.Palette.accent)
                                } else {
                                    Image(systemName: "circle")
                                        .foregroundStyle(Tokens.Palette.textTertiary)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selected.contains(friend.id) ? .isSelected : [])

                        // VISIBLE, not a swipe action. Setting an address is
                        // the whole reason you're in here for a member without
                        // one — hiding it behind a gesture nobody thinks to try
                        // is the same as not shipping it (device report
                        // 2026-08-03).
                        //
                        // PUSHES the shared address list rather than owning a
                        // second, subtly different editor. The one that lived
                        // here wrote each new place under the searched place's
                        // NAME, which never matched the previous label, so
                        // "Change address" appended a row and left the old
                        // address in force — inert on every use after the first
                        // (audit 2026-08-04).
                        //
                        // A programmatic push, not a `NavigationLink`: a link
                        // inside a List row makes the List draw its own
                        // disclosure chevron, which collided with the row's
                        // selection control and read as two competing
                        // affordances (sim check 2026-08-04).
                        Button { addressTarget = friend.id } label: {
                            Image(systemName: friend.primaryPlace == nil
                                  ? "plus.circle.fill" : "house.fill")
                                .font(Tokens.Typography.headline)
                                .foregroundStyle(friend.primaryPlace == nil
                                                 ? Tokens.Palette.brand : Tokens.Palette.textTertiary)
                                .frame(width: Tokens.Layout.minTapTarget,
                                       height: Tokens.Layout.minTapTarget)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(friend.primaryPlace == nil
                                            ? "Set \(friend.name)'s address"
                                            : "Change \(friend.name)'s address")
                      }
                    }
                } header: {
                    Text("Members")
                } footer: {
                    Text("Opening a group drops every member's home base on the map and finds fair spots between all of you — nobody has to share live location.")
                }
                if let group {
                    Section {
                        Button(role: .destructive) {
                            onDelete(group.id)
                            dismiss()
                        } label: {
                            Label("Delete Group", systemImage: "trash")
                        }
                    }
                }
            }
            // Keyed on the ID, not the struct: the destination has to rebuild
            // from the RELOADED roster after a write, or the pushed list keeps
            // showing the addresses the row had when it was tapped.
            .navigationDestination(item: $addressTarget) { id in
                if let friend = friends.first(where: { $0.id == id }) {
                    FriendPlacesList(
                        friend: friend,
                        searchRegion: searchRegion,
                        resolvePlace: resolvePlace,
                        onChanged: {
                            // Reload so the row updates without closing the
                            // group; tell the parent too — its copy is what
                            // openGroup reads, and a stale one made the whole
                            // feature refuse to open.
                            friends = FriendRoster.load()
                            onRosterChanged()
                        })
                }
            }
            .navigationTitle(group == nil ? "New Group" : "Edit Group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { onCancel(); dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        let trimmed = name.trimmingCharacters(in: .whitespaces)
                        // Keep the roster's order so the group renders stably.
                        let members = resolvedMembers
                        onSave(FriendGroup(id: group?.id ?? UUID(), name: trimmed, memberIDs: members))
                        dismiss()
                    }
                    .disabled(!canSave)
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private func toggle(_ id: UUID) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }
}

#Preview {
    GroupEditorSheet(friends: [
        TweenFriend(name: "Kavi", homeBaseLatitude: 37.33, homeBaseLongitude: -121.89, homeBaseLabel: "Kavi's place"),
        TweenFriend(name: "Maya")
    ])
}
