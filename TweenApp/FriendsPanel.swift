import SwiftUI
import Contacts
import MessageUI

/// Which face of the bottom sheet is showing: place search, or the friend
/// roster you're waiting on.
enum HomePanelTab: String, CaseIterable, Identifiable {
    case map
    case waiting

    var id: String { rawValue }

    var title: String {
        switch self {
        case .map:     return "Search"
        case .waiting: return "Friends"
        }
    }
}

/// Drives the rename flow. Held as optional state; non-nil presents the editor.
enum FriendEditor: Identifiable {
    case rename(TweenFriend)

    var id: UUID {
        switch self {
        case .rename(let friend): return friend.id
        }
    }

    var friend: TweenFriend {
        switch self {
        case .rename(let friend): return friend
        }
    }
}

/// A single roster row: avatar, name, and a subtitle that prefers the last-ping
/// relative time over the friend's handle.
///
/// `pingTick` is intentionally stored but unread — bumping it from the parent
/// changes this view's identity, forcing `pingSubtitle` to re-read the log so
/// "just now" appears the instant a ping lands.
struct FriendRow: View {
    let friend: TweenFriend
    let pingTick: Int

    var body: some View {
        HStack(spacing: Tokens.Spacing.s3) {
            Image(systemName: "person.crop.circle.fill")
                .font(Tokens.Typography.title2)
                .foregroundStyle(Tokens.Palette.brand)
                .frame(width: Tokens.Spacing.s7)
            VStack(alignment: .leading, spacing: Tokens.Spacing.s1) {
                Text(friend.name)
                    .font(Tokens.Typography.headline)
                    .lineLimit(1)
                Text(pingSubtitle)
                    .font(Tokens.Typography.caption)
                    .foregroundStyle(Tokens.Palette.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "paperplane.fill")
                .foregroundStyle(Tokens.Palette.textSecondary)
        }
        .padding(.vertical, Tokens.Spacing.s1)
        .accessibilityElement(children: .combine)
    }

    private var pingSubtitle: String {
        if let last = PingLog.lastPing(for: friend.id) {
            return "Pinged \(RelativeTime.string(from: last))"
        }
        return friend.handle ?? "No number on file"
    }
}

/// Modal contact picker. Requests Contacts access, searches by name, and hands
/// the chosen person back as a `TweenFriend` (name + first phone/email handle).
struct ContactSearchView: View {
    let onPick: (TweenFriend) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var status = CNContactStore.authorizationStatus(for: .contacts)
    @State private var matches: [CNContact] = []

    private let store = CNContactStore()

    var body: some View {
        NavigationStack {
            Group {
                switch status {
                case .authorized:
                    contactList
                case .denied, .restricted:
                    deniedState
                default:
                    requestState
                }
            }
            .navigationTitle("Add Friend")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .onAppear(perform: requestIfNeeded)
    }

    @ViewBuilder
    private var contactList: some View {
        List {
            ForEach(matches, id: \.identifier) { contact in
                let name = Self.fullName(contact)
                let handle = Self.handle(contact)
                Button {
                    onPick(TweenFriend(name: name,
                                       contactIdentifier: contact.identifier,
                                       handle: handle))
                } label: {
                    VStack(alignment: .leading, spacing: Tokens.Spacing.s1) {
                        Text(name).font(Tokens.Typography.headline)
                        if let handle {
                            Text(handle).font(Tokens.Typography.caption).foregroundStyle(Tokens.Palette.textSecondary)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityHint("Adds \(name) to your friends")
            }
        }
        .listStyle(.plain)
        .searchable(text: $query, prompt: "Search contacts")
        .onChange(of: query) { _, _ in runSearch() }
        .overlay {
            if !query.isEmpty && matches.isEmpty {
                Text("No contacts found.")
                    .font(Tokens.Typography.footnote)
                    .foregroundStyle(Tokens.Palette.textSecondary)
            }
        }
    }

    private var requestState: some View {
        ProgressView().onAppear(perform: requestIfNeeded)
    }

    private var deniedState: some View {
        ContentUnavailableView(
            "Contacts Access Off",
            systemImage: "person.crop.circle.badge.xmark",
            description: Text("Enable Contacts access in Settings to add friends from your address book."))
    }

    private func requestIfNeeded() {
        guard status == .notDetermined else { return }
        store.requestAccess(for: .contacts) { _, _ in
            DispatchQueue.main.async {
                status = CNContactStore.authorizationStatus(for: .contacts)
            }
        }
    }

    /// Name-predicate fetch off the main thread; results land back on main.
    private func runSearch() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { matches = []; return }

        Task.detached(priority: .userInitiated) {
            let predicate = CNContact.predicateForContacts(matchingName: trimmed)
            let keys = [
                CNContactGivenNameKey, CNContactFamilyNameKey,
                CNContactPhoneNumbersKey, CNContactEmailAddressesKey
            ] as [CNKeyDescriptor]
            let found = (try? store.unifiedContacts(matching: predicate, keysToFetch: keys)) ?? []
            await MainActor.run { matches = found }
        }
    }

    private static func fullName(_ contact: CNContact) -> String {
        let name = [contact.givenName, contact.familyName]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return name.isEmpty ? (handle(contact) ?? "Unknown") : name
    }

    private static func handle(_ contact: CNContact) -> String? {
        if let phone = contact.phoneNumbers.first?.value.stringValue, !phone.isEmpty {
            return phone
        }
        if let email = contact.emailAddresses.first?.value as String?, !email.isEmpty {
            return email
        }
        return nil
    }
}

/// SwiftUI bridge to the system SMS composer. Presented with recipients and a
/// prefilled body; `onFinish` fires on send/cancel so the host can clear it.
struct MessageComposeSheet: UIViewControllerRepresentable {
    let recipients: [String]
    let body: String
    let onFinish: () -> Void

    func makeUIViewController(context: Context) -> MFMessageComposeViewController {
        let controller = MFMessageComposeViewController()
        controller.recipients = recipients
        controller.body = body
        controller.messageComposeDelegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: MFMessageComposeViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    final class Coordinator: NSObject, MFMessageComposeViewControllerDelegate {
        let onFinish: () -> Void
        init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }

        func messageComposeViewController(_ controller: MFMessageComposeViewController,
                                          didFinishWith result: MessageComposeResult) {
            onFinish()
        }
    }
}
