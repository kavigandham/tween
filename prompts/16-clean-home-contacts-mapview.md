# Fix: Clean Home Screen, Pre-loaded Contacts, Distinct Search vs List View

Read CLAUDE.md before making changes. Do NOT run any build tools.
Read TweenApp/OnboardingView.swift thoroughly before making changes.

## Fix 1: Clean Apple Maps-style Home Screen

On launch, the user should see a full-screen map with JUST a search bar at the bottom. No buttons, no panels, no clutter — like Apple Maps.

### Current problem
The bottom sheet is always visible with "I'm in" buttons, category chips, tabs, and other UI cluttering the first impression.

### The fix
On launch (before any search), the bottom sheet should show only the search bar:

```
┌──────────────────────────────────────┐
│                                      │
│            Full screen map           │
│          (user's location)           │
│                                      │
│                                      │
│                                      │
├──────────────────────────────────────┤
│  🔍 Search for a spot...             │
└──────────────────────────────────────┘
```

Implementation:
1. Default sheet detent: `.height(70)` — just the search bar with padding.
2. Hide "I'm in", category chips, tab toggles, and friend panel from this minimal state. They appear only when the sheet is pulled up.
3. Search bar: clean `TextField` with magnifying glass icon, placeholder "Search for a spot..."
4. Pulling up reveals full UI (chips, "I'm in", friends tab, etc.)
5. Map fills the screen when sheet is at minimum.

Sheet detents:
```swift
.presentationDetents([
    .height(70),        // Just search bar — DEFAULT
    .fraction(0.45),    // Medium — chips + results
    .fraction(0.85)     // Full — everything
])
```

Initial detent: `.height(70)`.

What's visible at each detent:
- **Minimal (.height(70)):** Search bar only.
- **Medium (.fraction(0.45)):** Search bar + category chips + "I'm in" + results.
- **Full (.fraction(0.85)):** Everything including friends panel.

When user taps the search bar: animate sheet to medium to show chips and make room for results.

## Fix 2: Pre-load All Contacts in "Add Friend"

### Current problem
Contact sheet is BLANK when opened. User has to type before any contacts appear.

### The fix
Load ALL contacts immediately on sheet open. Search field filters the pre-loaded list.

```swift
struct ContactSearchSheet: View {
    @State private var allContacts: [ContactCandidate] = []
    @State private var searchText = ""
    @State private var permissionGranted = false
    @Environment(\.dismiss) private var dismiss
    
    var filteredContacts: [ContactCandidate] {
        if searchText.isEmpty { return allContacts }
        return allContacts.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }
    
    var body: some View {
        NavigationStack {
            VStack {
                if !permissionGranted {
                    Text("Tween needs access to your contacts to add friends")
                    Button("Allow Access") { requestAccess() }
                } else if allContacts.isEmpty {
                    ProgressView("Loading contacts...")
                } else {
                    TextField("Search contacts", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                        .padding(.horizontal)
                    
                    List(filteredContacts, id: \.id) { contact in
                        Button { addFriend(contact) } label: {
                            HStack {
                                ZStack {
                                    Circle()
                                        .fill(Tokens.Palette.brand.opacity(0.15))
                                        .frame(width: 40, height: 40)
                                    Text(contact.initials)
                                        .font(Tokens.Typography.callout)
                                        .foregroundStyle(Tokens.Palette.brand)
                                }
                                VStack(alignment: .leading) {
                                    Text(contact.name)
                                        .font(Tokens.Typography.headline)
                                    if let phone = contact.phone {
                                        Text(phone)
                                            .font(Tokens.Typography.caption)
                                            .foregroundStyle(Tokens.Palette.textSecondary)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Add Friend")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task { await loadAllContacts() }
        }
    }
    
    func loadAllContacts() async {
        let store = CNContactStore()
        let status = CNContactStore.authorizationStatus(for: .contacts)
        if status == .notDetermined {
            do {
                let granted = try await store.requestAccess(for: .contacts)
                permissionGranted = granted
                if !granted { return }
            } catch { return }
        } else if status == .authorized {
            permissionGranted = true
        } else { return }
        
        let keys: [CNKeyDescriptor] = [
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactIdentifierKey as CNKeyDescriptor
        ]
        var contacts: [ContactCandidate] = []
        let request = CNContactFetchRequest(keysToFetch: keys)
        request.sortOrder = .givenName
        do {
            try store.enumerateContacts(with: request) { contact, _ in
                let name = [contact.givenName, contact.familyName].filter { !$0.isEmpty }.joined(separator: " ")
                guard !name.isEmpty else { return }
                let phone = contact.phoneNumbers.first?.value.stringValue
                let initials = String(contact.givenName.prefix(1) + contact.familyName.prefix(1)).uppercased()
                contacts.append(ContactCandidate(id: contact.identifier, name: name, phone: phone, initials: initials.isEmpty ? "?" : initials))
            }
        } catch {}
        await MainActor.run { allContacts = contacts }
    }
}

struct ContactCandidate: Identifiable {
    let id: String
    let name: String
    let phone: String?
    let initials: String
}
```

## Fix 3: Distinct Search Suggestions vs List View Results

Search suggestions (while typing) and final results (after pressing Enter) must look completely different.

### State management
```swift
enum SearchState {
    case idle           // nothing searched
    case suggesting     // user is typing, show completer suggestions
    case results        // user pressed Enter, show full result cards
}
@State private var searchState: SearchState = .idle
```

- User starts typing → `.suggesting` → show suggestion rows
- User presses Enter or taps a suggestion → `.results` → show result cards  
- User clears search → `.idle` → show category chips

### SEARCH SUGGESTIONS (while typing) — compact rows

Powered by `MKLocalSearchCompleter`. Simple, scannable rows:

```swift
ForEach(searchCompleter.results, id: \.self) { completion in
    Button {
        searchText = completion.title
        commitSearch()
    } label: {
        HStack(spacing: 12) {
            VStack {
                Image(systemName: "mappin.circle.fill")
                    .font(.title3)
                    .foregroundStyle(Tokens.Palette.textSecondary)
            }
            .frame(width: 40)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(completion.title)
                    .font(Tokens.Typography.headline)
                    .foregroundStyle(Tokens.Palette.textPrimary)
                if !completion.subtitle.isEmpty {
                    Text(completion.subtitle)
                        .font(Tokens.Typography.caption)
                        .foregroundStyle(Tokens.Palette.textSecondary)
                        .lineLimit(1)
                }
            }
            
            Spacer()
            
            Image(systemName: "arrow.up.left")
                .font(.caption)
                .foregroundStyle(Tokens.Palette.textTertiary)
        }
        .padding(.vertical, 8)
    }
    Divider()
}
```

### LIST VIEW RESULTS (after committing search) — rich cards

Powered by `MKLocalSearch` full `MKMapItem` results. Each card shows:

```swift
struct ResultCard: View {
    let item: MKMapItem
    let rankedSpot: RankedSpot?
    let userCoord: CLLocationCoordinate2D?
    let onDirections: () -> Void
    let onSendToChat: () -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(item.name ?? "Unknown")
                .font(Tokens.Typography.title)
            
            if let category = item.pointOfInterestCategory?.displayName {
                Text(category)
                    .font(Tokens.Typography.callout)
                    .foregroundStyle(Tokens.Palette.textSecondary)
            }
            
            HStack {
                if let dist = distanceString {
                    Text(dist)
                        .font(Tokens.Typography.callout)
                        .foregroundStyle(Tokens.Palette.brand)
                }
                if let address = item.placemark.title {
                    Text(address)
                        .font(Tokens.Typography.caption)
                        .foregroundStyle(Tokens.Palette.textSecondary)
                        .lineLimit(1)
                }
            }
            
            if let spot = rankedSpot {
                HStack(spacing: 4) {
                    Text("A \(formatETA(spot.etaFromA))")
                        .font(Tokens.Typography.captionBold)
                    Text("·")
                    Text("B \(formatETA(spot.etaFromB))")
                        .font(Tokens.Typography.captionBold)
                        .foregroundStyle(Tokens.Palette.textSecondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Tokens.Palette.brand.opacity(0.1))
                .clipShape(Capsule())
            }
            
            HStack(spacing: 12) {
                Button { onDirections() } label: {
                    Label("Directions", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                }
                .buttonStyle(.tweenPrimary(.subtle))
                
                if let phone = item.phoneNumber, !phone.isEmpty {
                    Button {
                        if let url = URL(string: "tel:\(phone)") {
                            UIApplication.shared.open(url)
                        }
                    } label: {
                        Label("Call", systemImage: "phone.fill")
                    }
                    .buttonStyle(.tweenPrimary(.subtle))
                }
                
                Button { onSendToChat() } label: {
                    Label("Send", systemImage: "paperplane.fill")
                }
                .buttonStyle(.tweenPrimary(.subtle))
            }
        }
        .padding(Tokens.Spacing.s4)
        .background(Tokens.Palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.card))
        .tweenElevation(Tokens.Elevation.floating)
    }
    
    var distanceString: String? {
        guard let coord = userCoord else { return nil }
        let from = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
        let to = CLLocation(latitude: item.placemark.coordinate.latitude, longitude: item.placemark.coordinate.longitude)
        let miles = from.distance(from: to) / 1609.34
        return String(format: "%.1f mi", miles)
    }
}
```

### Category display name helper
```swift
extension MKPointOfInterestCategory {
    var displayName: String? {
        switch self {
        case .restaurant: return "Restaurant"
        case .cafe: return "Cafe"
        case .bakery: return "Bakery"
        case .store: return "Store"
        case .gasStation: return "Gas Station"
        case .park: return "Park"
        case .nightlife: return "Nightlife"
        case .theater: return "Theater"
        case .fitnessCenter: return "Fitness"
        default: return nil
        }
    }
}
```

## After fixing
Commit with message: "fix: clean home screen, pre-loaded contacts, distinct search suggestions vs result cards"
