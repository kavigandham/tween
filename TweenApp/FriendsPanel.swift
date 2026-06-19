import SwiftUI
@preconcurrency import Contacts
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

/// Modal contact picker. Requests Contacts access, pre-loads the full address
/// book on open (so the list is never blank), filters it locally as you type,
/// and hands the chosen person back as a `TweenFriend` (name + first phone/email
/// handle).
struct ContactSearchView: View {
    let onPick: (TweenFriend) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var status = CNContactStore.authorizationStatus(for: .contacts)
    @State private var allContacts: [CNContact] = []
    @State private var isLoading = false

    private let store = CNContactStore()

    /// The pre-loaded list, narrowed to the typed query (case-insensitive name
    /// match). An empty query shows everyone.
    private var filtered: [CNContact] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return allContacts }
        return allContacts.filter { Self.fullName($0).localizedCaseInsensitiveContains(trimmed) }
    }

    var body: some View {
        NavigationStack {
            Group {
                switch status {
                case .authorized:
                    if allContacts.isEmpty {
                        if isLoading {
                            ProgressView("Loading contacts…")
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            ContentUnavailableView(
                                "No Contacts",
                                systemImage: "person.crop.circle",
                                description: Text("There are no named contacts to add."))
                        }
                    } else {
                        contactList
                    }
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
        .task { await loadAllContacts() }
    }

    private var contactList: some View {
        List(filtered, id: \.identifier) { contact in
            let name = Self.fullName(contact)
            let handle = Self.handle(contact)
            Button {
                onPick(TweenFriend(name: name,
                                   contactIdentifier: contact.identifier,
                                   handle: handle))
            } label: {
                HStack(spacing: Tokens.Spacing.s3) {
                    ZStack {
                        Circle()
                            .fill(Tokens.Palette.brand.opacity(0.15))
                            .frame(width: 40, height: 40)
                        Text(Self.initials(contact))
                            .font(Tokens.Typography.callout)
                            .foregroundStyle(Tokens.Palette.brand)
                    }
                    VStack(alignment: .leading, spacing: Tokens.Spacing.s1) {
                        Text(name).font(Tokens.Typography.headline)
                        if let handle {
                            Text(handle)
                                .font(Tokens.Typography.caption)
                                .foregroundStyle(Tokens.Palette.textSecondary)
                        }
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityHint("Adds \(name) to your friends")
        }
        .listStyle(.plain)
        .searchable(text: $query, prompt: "Search contacts")
        .overlay {
            if !query.isEmpty && filtered.isEmpty {
                Text("No contacts found.")
                    .font(Tokens.Typography.footnote)
                    .foregroundStyle(Tokens.Palette.textSecondary)
            }
        }
    }

    private var requestState: some View {
        // Permission is requested from `loadAllContacts`; this is the in-flight
        // spinner shown while the system prompt is up.
        ProgressView()
    }

    private var deniedState: some View {
        ContentUnavailableView(
            "Contacts Access Off",
            systemImage: "person.crop.circle.badge.xmark",
            description: Text("Enable Contacts access in Settings to add friends from your address book."))
    }

    /// Requests access if needed, then enumerates the whole address book once on
    /// the background queue and publishes named contacts (sorted by given name)
    /// back to the list.
    private func loadAllContacts() async {
        if status == .notDetermined {
            let granted = (try? await store.requestAccess(for: .contacts)) ?? false
            status = CNContactStore.authorizationStatus(for: .contacts)
            guard granted else { return }
        } else if status != .authorized {
            return
        }
        guard allContacts.isEmpty else { return }

        isLoading = true
        let localStore = store
        let loaded: [CNContact] = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let keys = [
                    CNContactGivenNameKey, CNContactFamilyNameKey,
                    CNContactPhoneNumbersKey, CNContactEmailAddressesKey
                ] as [CNKeyDescriptor]
                let request = CNContactFetchRequest(keysToFetch: keys)
                request.sortOrder = .givenName
                var result: [CNContact] = []
                do {
                    try localStore.enumerateContacts(with: request) { contact, _ in
                        let hasName = !contact.givenName.isEmpty || !contact.familyName.isEmpty
                        if hasName { result.append(contact) }
                    }
                } catch {}
                continuation.resume(returning: result)
            }
        }
        allContacts = loaded
        isLoading = false
    }

    /// Two-letter initials from the given/family name; "?" when neither exists.
    private static func initials(_ contact: CNContact) -> String {
        let first = contact.givenName.first.map(String.init) ?? ""
        let last = contact.familyName.first.map(String.init) ?? ""
        let combined = (first + last).uppercased()
        return combined.isEmpty ? "?" : combined
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
