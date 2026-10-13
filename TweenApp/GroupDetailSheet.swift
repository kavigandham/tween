import SwiftUI
import MapKit

/// One saved group, opened.
///
/// The screen's job is the BUTTON: Start a Tween. Everything a group can do to
/// itself — rename, drop a member, delete — is real but secondary, tucked into
/// a Group settings section below the fold, because a group you open ten times
/// to meet up and once to rename should not read as an admin form (spec §7).
///
/// Tapping a group row used to run the search immediately, which meant there
/// was nowhere to see who was in the group, nowhere to rename it, and no way
/// to tell an empty result ("nobody has an address yet") from a mistake. This
/// is that missing screen.
struct GroupDetailSheet: View {
    /// The group as the presenter last loaded it. Re-read from the store on
    /// appear and after every write, so an edit made here (or in the editor
    /// pushed from here) is never rendered from a stale copy.
    let groupID: UUID
    /// Pro gates STARTING a group search, matching the existing group rows.
    var proUnlocked: Bool = true
    var onStart: (FriendGroup) -> Void = { _ in }
    var onUpgrade: () -> Void = {}
    var onEditMembers: (FriendGroup) -> Void = { _ in }
    var onDelete: (UUID) -> Void = { _ in }
    var onChanged: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @State private var group: FriendGroup?
    @State private var friends: [TweenFriend]
    @State private var renaming = false
    @State private var renameText = ""
    @State private var confirmingDelete = false

    /// `roster` seeds the member list so the sheet has something to draw on
    /// its first frame; `reload()` replaces it from the store on appear, which
    /// is what keeps an edit made here (or in the editor pushed from here)
    /// from being rendered off a stale copy.
    init(groupID: UUID,
         roster: [TweenFriend],
         proUnlocked: Bool = true,
         onStart: @escaping (FriendGroup) -> Void = { _ in },
         onUpgrade: @escaping () -> Void = {},
         onEditMembers: @escaping (FriendGroup) -> Void = { _ in },
         onDelete: @escaping (UUID) -> Void = { _ in },
         onChanged: @escaping () -> Void = {}) {
        self.groupID = groupID
        self.proUnlocked = proUnlocked
        self.onStart = onStart
        self.onUpgrade = onUpgrade
        self.onEditMembers = onEditMembers
        self.onDelete = onDelete
        self.onChanged = onChanged
        _friends = State(initialValue: roster)
        _group = State(initialValue: GroupStore.group(id: groupID))
    }

    private var members: [TweenFriend] {
        group?.members(in: friends) ?? []
    }

    /// Members Tween can actually put on the map. A group whose members have
    /// no saved addresses can't be searched from — saying so here is the
    /// difference between "nothing happened" and "here's what to fix".
    private var locatedCount: Int {
        members.filter { $0.homeBase != nil }.count
    }

    var body: some View {
        NavigationStack {
            Group {
                if let group {
                    content(for: group)
                } else {
                    // The group was deleted from under us (another sheet, a
                    // second tap). Say so rather than rendering an empty
                    // screen that looks broken (spec §28).
                    ContentUnavailableView(
                        "Group not found",
                        systemImage: "person.3",
                        description: Text("This group has been deleted."))
                }
            }
            .navigationTitle(group?.name ?? "Group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Rename group", isPresented: $renaming) {
                TextField("Group name", text: $renameText)
                Button("Save") { commitRename() }
                Button("Cancel", role: .cancel) {}
            }
            .alert("Delete \(group?.name ?? "group")?", isPresented: $confirmingDelete) {
                Button("Delete", role: .destructive) {
                    onDelete(groupID)
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Your friends stay in your list — only the group is removed.")
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .onAppear { reload() }
    }

    @ViewBuilder
    private func content(for group: FriendGroup) -> some View {
        List {
            Section {
                membersStrip
                startButton(for: group)
                    .listRowSeparator(.hidden)
            }
            .listRowBackground(Color.clear)

            if !group.recentTweens.isEmpty {
                Section("Recent Tweens") {
                    ForEach(group.recentTweens) { tween in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(tween.title)
                                .foregroundStyle(Tokens.Palette.textPrimary)
                            Text(Self.relativeDay(tween.startedAt))
                                .font(Tokens.Typography.caption)
                                .foregroundStyle(Tokens.Palette.textSecondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }

            Section {
                ForEach(members) { member in
                    HStack(spacing: Tokens.Spacing.s3) {
                        TweenRowIcon(systemImage: "person.fill",
                                     color: Tokens.Palette.textSecondary, size: 32)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(member.name)
                                .foregroundStyle(Tokens.Palette.textPrimary)
                            Text(member.primaryPlace?.label ?? "No address yet")
                                .font(Tokens.Typography.caption)
                                .foregroundStyle(member.primaryPlace == nil
                                                 ? Tokens.Palette.textTertiary
                                                 : Tokens.Palette.textSecondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) { remove(member) } label: {
                            Label("Remove", systemImage: "person.badge.minus")
                        }
                    }
                }
                Button { onEditMembers(group) } label: {
                    Label("Add or change members", systemImage: "person.badge.plus")
                }
            } header: {
                Text("Members")
            } footer: {
                Text(locatedCount == members.count
                     ? "Everyone has a saved address, so Tween can rank spots between all of you."
                     : "\(members.count - locatedCount) of \(members.count) have no saved address yet — add one and they'll be included.")
            }

            Section("Group settings") {
                Button {
                    renameText = group.name
                    renaming = true
                } label: {
                    Label("Rename group", systemImage: "pencil")
                }
                Button(role: .destructive) { confirmingDelete = true } label: {
                    // The role tints the TEXT red, but the Label's symbol
                    // inherits the List's blue tint — red words, blue trash
                    // (screenshot audit 2026-10-13).
                    Label("Delete group", systemImage: "trash")
                        .foregroundStyle(Tokens.Palette.destructive)
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    /// The member faces, the thing you check before you tap Start.
    private var membersStrip: some View {
        HStack(spacing: Tokens.Spacing.s3) {
            ForEach(members.prefix(5)) { member in
                VStack(spacing: Tokens.Spacing.s1) {
                    Text(OnboardingView.initials(for: member.name))
                        .font(Tokens.Typography.subheadline.weight(.semibold))
                        .foregroundStyle(Tokens.Palette.onBrand)
                        .frame(width: 44, height: 44)
                        .background(Tokens.Palette.brand, in: Circle())
                    Text(GroupNaming.firstName(member.name))
                        .font(Tokens.Typography.caption)
                        .foregroundStyle(Tokens.Palette.textSecondary)
                        .lineLimit(1)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(member.name)
            }
            if members.count > 5 {
                Text("+\(members.count - 5)")
                    .font(Tokens.Typography.subheadline.weight(.semibold))
                    .foregroundStyle(Tokens.Palette.textSecondary)
                    .frame(width: 44, height: 44)
                    .background(Tokens.Palette.neutralAction, in: Circle())
                    .accessibilityLabel("\(members.count - 5) more members")
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, Tokens.Spacing.s2)
    }

    private func startButton(for group: FriendGroup) -> some View {
        Button {
            guard proUnlocked else { onUpgrade(); return }
            onStart(group)
        } label: {
            Label("Start a Tween", systemImage: "mappin.and.ellipse")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.tweenPrimary())
        .accessibilityHint("Puts everyone's saved address on the map and finds fair spots between them")
    }

    // MARK: - Writes

    private func reload() {
        group = GroupStore.group(id: groupID)
        friends = FriendRoster.load()
    }

    private func commitRename() {
        GroupStore.rename(id: groupID, to: renameText)
        reload()
        onChanged()
    }

    private func remove(_ member: TweenFriend) {
        GroupStore.removeMember(member.id, from: groupID)
        reload()
        onChanged()
    }

    /// "Yesterday" / "Saturday" / "12 Aug" — the resolution people actually
    /// hold in their heads for "when did we last go out".
    static func relativeDay(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        let days = calendar.dateComponents([.day], from: date, to: now).day ?? 0
        if days < 7 {
            return date.formatted(.dateTime.weekday(.wide))
        }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }
}
