import SwiftUI

/// Create or edit a friend group (Pro): name the group, tick its members.
/// Rows surface each friend's home-base status because the group's whole
/// point is opening it into an instant fair-spot search — a member without a
/// home base just won't land on the map until one is set.
struct GroupEditorSheet: View {
    /// nil = creating a new group.
    var group: FriendGroup?
    let friends: [TweenFriend]
    var onSave: (FriendGroup) -> Void = { _ in }
    var onDelete: (UUID) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var selected: Set<UUID>

    init(group: FriendGroup? = nil, friends: [TweenFriend],
         onSave: @escaping (FriendGroup) -> Void = { _ in },
         onDelete: @escaping (UUID) -> Void = { _ in }) {
        self.group = group
        self.friends = friends
        self.onSave = onSave
        self.onDelete = onDelete
        _name = State(initialValue: group?.name ?? "")
        _selected = State(initialValue: Set(group?.memberIDs ?? []))
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && !selected.isEmpty
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
                        Button { toggle(friend.id) } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(friend.name)
                                        .foregroundStyle(Tokens.Palette.textPrimary)
                                    if let label = friend.homeBaseLabel, friend.homeBase != nil {
                                        Label(label, systemImage: "house.fill")
                                            .font(Tokens.Typography.caption)
                                            .foregroundStyle(Tokens.Palette.textSecondary)
                                    } else {
                                        Text("No home base yet")
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
                        }
                        .accessibilityAddTraits(selected.contains(friend.id) ? .isSelected : [])
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
            .navigationTitle(group == nil ? "New Group" : "Edit Group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        let trimmed = name.trimmingCharacters(in: .whitespaces)
                        // Keep the roster's order so the group renders stably.
                        let members = friends.filter { selected.contains($0.id) }.map(\.id)
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
