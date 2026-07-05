# Tween UI Pattern Reference

Correct, bug-free UI patterns for a SwiftUI iOS app with two targets: a host app (SwiftUI) and an iMessage extension (UIKit hosting SwiftUI via `UIHostingController` inside `MSMessagesAppViewController`). The extension has a **~120 MB memory ceiling**.

Section numbers below are stable — the master prompt references them as §1–§12.

---

## §1. SwiftUI Bottom Sheet (`.sheet` + `PresentationDetent`)

**Correct Pattern:**
```swift
// ONE sheet, routed by an enum. This is the fix for multi-.sheet conflicts.
enum ActiveSheet: Identifiable {
    case meetup, friends, spotDetail(String)
    var id: String {
        switch self {
        case .meetup: return "meetup"
        case .friends: return "friends"
        case .spotDetail(let s): return "spot-\(s)"
        }
    }
}

struct MapScreen: View {
    @State private var activeSheet: ActiveSheet?
    @State private var detent: PresentationDetent = .fraction(0.35)

    var body: some View {
        Map(/* ... */)
            .sheet(item: $activeSheet) { sheet in
                sheetBody(for: sheet)
                    .presentationDetents([.fraction(0.35), .large], selection: $detent)
                    .presentationBackgroundInteraction(.enabled(upThrough: .fraction(0.35)))
                    .interactiveDismissDisabled()          // persistent sheet, never dismisses
                    .presentationDragIndicator(.visible)
            }
    }
}
```

**Persistent Apple-Maps-style sheet** (always present over a full-screen map): present it once on appear, then `.interactiveDismissDisabled()` so a swipe-down parks it at the smallest detent instead of dismissing. `.presentationBackgroundInteraction(.enabled(upThrough:))` lets the map stay pannable while the sheet sits at or below that detent — this is the "largestUndimmedDetentIdentifier" equivalent in SwiftUI.

**Common Mistakes:**
```swift
// BROKEN 1: two .sheet modifiers on one view. Only one presents; the other
// silently no-ops or races. This is the Tween multi-sheet bug.
.sheet(isPresented: $showA) { AView() }
.sheet(isPresented: $showB) { BView() }   // conflicts with the first

// BROKEN 2: a poll re-asserting the detent selection every tick.
// The 1Hz LocationCache poll writes `detent` back, fighting the user's drag
// mid-gesture — this is the "sheet self-jump."
.onReceive(locationPoll) { _ in
    detent = .fraction(0.35)   // <-- re-asserts selection, yanks the sheet
}
```

**The self-jump fix:** never let a timer/poll write the detent selection binding. Gate it — only set the detent from explicit user intent (a button, a search commit), never from the recurring poll. If the poll must nudge the sheet, compare-and-skip:
```swift
.onReceive(locationPoll) { _ in
    // do NOT touch `detent` here. Update data only.
}
```

**Gotchas:**
- `selection:` binding + frequent state writes = jump. The binding is authoritative; anything that writes it wins over the user's finger.
- Keyboard appearing forces the sheet toward `.large`; detents smaller than the keyboard are unreachable while it's up.
- Changing the sheet's inner content size does **not** re-fit detents — detents are fixed heights, not content-driven.
- `.sheet(item:)` re-presents when the item's `id` changes; keep `id` stable or the sheet flickers.

**iOS Version Notes:**
- `PresentationDetent`, `.presentationBackgroundInteraction`, `.presentationDragIndicator`: iOS 16.4+.
- iOS 17 stabilized `selection:` behavior; pre-17.1 had extra detent-snap jank on rotation.
- iOS 18 / 26: no documented API change to detents; treat 26 specifics as unverified.

**Memory/Performance:** Sheets are cheap. The cost here is *correctness*, not memory.

**Sources:** Apple `presentationDetents(_:selection:)` docs; WWDC22 "Customize and resize sheets in UIKit" (SwiftUI parallels); community reports of `selection:` gesture-fighting on Apple Developer Forums.

---

## §2. SwiftUI Map View (iOS 17+)

**Correct Pattern:**
```swift
@State private var camera: MapCameraPosition = .automatic

Map(position: $camera) {
    ForEach(spots) { spot in
        Annotation(spot.name, coordinate: spot.coord) {
            SpotPin()                 // custom view, ≥44pt tap target
                .contentShape(Rectangle())
        }
    }
    UserAnnotation()
}
.mapControls { MapUserLocationButton(); MapCompass() }
.safeAreaPadding(.bottom, sheetHeight)   // keeps pins clear of the sheet
.onMapCameraChange(frequency: .onEnd) { ctx in
    // detect user pan/zoom here
}

// Zoom-to-fit a set of coordinates:
func fit(_ coords: [CLLocationCoordinate2D]) {
    guard let rect = coords.mapRect() else { return }
    withAnimation(.easeInOut) {
        camera = .rect(rect.insetBy(dx: -2000, dy: -2000))
    }
}
```

**Common Mistakes:**
```swift
// BROKEN: writing `camera` from a poll while the user is panning.
// Same class of bug as the sheet self-jump — programmatic position fights the gesture.
.onReceive(poll) { _ in camera = .region(defaultRegion) }  // yanks the map back

// BROKEN: Marker when you need a tappable custom view.
Marker(spot.name, coordinate: spot.coord)   // not customizable, limited tap handling
```

**Gotchas:**
- `Annotation { }` = full custom view, your own tap target and anchor. `Marker` = system balloon, minimal control. Use `Annotation` for anything interactive.
- Programmatic `position` changes only "win" when the user isn't actively gesturing; writing every tick still causes visible fighting.
- `withAnimation` **does** animate camera changes to `position`.
- `.safeAreaPadding(.bottom,)` is how you offset the visible region under a sheet — not a frame change.
- No first-class clustering in SwiftUI Map yet; thin annotations manually by zoom via `onMapCameraChange`.

**iOS Version Notes:**
- New `Map(position:)` API is iOS 17+. The old `Map(coordinateRegion:)` is deprecated — do not mix.
- iOS 17.0 had camera-animation stutter fixed by 17.1.
- iOS 26 map behavior unverified.

**Memory/Performance:** **A live SwiftUI `Map` in the extension risks the 120 MB ceiling.** Do not use it there — use `MKMapSnapshotter` (§5). Live Map is fine in the host app.

**Sources:** Apple "Map" (SwiftUI) docs; WWDC23 "Meet MapKit for SwiftUI."

---

## §3. UIHostingController in iMessage Extensions

**Correct Pattern:**
```swift
func showHosted<V: View>(_ view: V) {
    let host = UIHostingController(rootView: view)
    host.view.backgroundColor = .clear          // or an opaque color; see below
    addChild(host)
    host.view.frame = self.view.bounds
    host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    self.view.addSubview(host.view)
    host.didMove(toParent: self)
    self.currentHost = host                      // RETAIN it
}
```

**Common Mistakes:**
```swift
// BROKEN 1: no didMove(toParent:) — SwiftUI lifecycle never fully starts,
// view can render blank.
addChild(host); view.addSubview(host.view)      // missing didMove

// BROKEN 2: not retaining the host — it deallocs, screen goes blank.
let host = UIHostingController(rootView: v)      // local, released after the call

// BROKEN 3: transparent background over nothing → blank/black frame.
// If the SwiftUI root has no opaque background, Messages shows blank.
```

**Blank-render causes (all of them):** missing `didMove(toParent:)`; host not retained; zero frame (added before `bounds` is set); fully transparent root with no backing; swapping root on a background thread; hosting controller recreated every lifecycle callback so state never settles.

**Swapping compact → expanded:** keep one host and swap `rootView`, or tear down cleanly (`willMove(toParent: nil)` → `removeFromSuperview` → `removeFromParent`) before adding the new one. Don't leak the old host.

**Gotchas:**
- `sizingOptions = .intrinsicContentSize` (iOS 16+) lets the host size to content — useful for compact, risky for full-bleed expanded.
- Writing `@State` from a background thread is undefined — marshal to `@MainActor`.

**iOS Version Notes:** `sizingOptions` iOS 16+. Behavior stable 17→18; 26 unverified.

**Memory/Performance:** `UIHostingController` overhead is small; the SwiftUI *content* (a live Map) is what blows the ceiling. Retain one host, don't churn.

**Sources:** Apple `UIHostingController` docs; Messages framework sample code.

---

## §4. `MSMessagesAppViewController` Lifecycle

**Correct Pattern:**
```swift
override func willBecomeActive(with conversation: MSConversation) {
    super.willBecomeActive(with: conversation)
    // Safe: read selectedMessage, participant IDs, build conversation key.
    // Render compact UI here.
}
override func willTransition(to style: MSMessagesAppPresentationStyle) {
    // Animate alongside; do NOT set first responder yet.
}
override func didTransition(to style: MSMessagesAppPresentationStyle) {
    // UI is now fully sized. Safe to focus a TextField / start search here.
}
```

**Common Mistakes:**
```swift
// BROKEN: requesting expansion and focusing in the same breath.
requestPresentationStyle(.expanded)
textField.becomeFirstResponder()   // too early — not sized yet; focus in didTransition
```

**Gotchas:**
- `selectedMessage` is `nil` on a fresh compose and can carry **stale** data after a send — validate before trusting.
- `localParticipantIdentifier` / `remoteParticipantIdentifiers` are stable *within* a conversation but meaningless across devices after URL delivery — fall back to names (Tween already does).
- `conversation.insert(_:)` can fail silently; always take the completion handler and log.
- `didReceive(_:conversation:)` fires on incoming message; `willBecomeActive` fires on open — they are not the same trigger.
- `requestPresentationStyle(.expanded)` can no-op if called before active.

**iOS Version Notes:** Simulator cannot send `MSMessage` on recent iOS — **real-device only** for round trips. "Extension missing from drawer" is almost always an Info.plist / bundle-ID mismatch, not code.

**Memory/Performance:** `didReceiveMemoryWarning()` in the extension is your cue to degrade the map to a static snapshot. Ceiling ~120 MB.

**Sources:** Apple `MSMessagesAppViewController` docs; WWDC16 "iMessage Apps and Stickers."

---

## §5. MKMapSnapshotter

**Correct Pattern:**
```swift
final class SnapshotMaker {
    private var snapshotter: MKMapSnapshotter?     // RETAIN until completion

    func make(region: MKCoordinateRegion, size: CGSize,
              pins: [CLLocationCoordinate2D],
              done: @escaping (UIImage?) -> Void) {
        let opts = MKMapSnapshotter.Options()
        opts.region = region
        opts.size = size
        opts.scale = UIScreen.main.scale           // @3x on Retina
        let snap = MKMapSnapshotter(options: opts)
        snapshotter = snap
        snap.start { [weak self] snapshot, _ in
            defer { self?.snapshotter = nil }
            guard let snapshot else { return done(nil) }
            let img = UIGraphicsImageRenderer(size: size).image { _ in
                snapshot.image.draw(at: .zero)
                for c in pins {
                    let p = snapshot.point(for: c)   // coord → image point
                    // draw pin at p
                }
            }
            done(img)
        }
    }
}
```

**Common Mistakes:**
```swift
// BROKEN: local snapshotter released before the async handler fires → blank.
let s = MKMapSnapshotter(options: o); s.start { ... }   // s deallocs immediately
```

**Gotchas:**
- Returns blank on zero size, bad region, or if released early.
- Apple tile servers rate-limit — throttle repeated snapshots.
- `snapshot.point(for:)` must run inside the same snapshot's coordinate space.

**iOS Version Notes:** Stable 17→18; 26 unverified.

**Memory/Performance:** This is the *reason* to use snapshotter in the extension — a static image instead of a live Map keeps you under 120 MB. Nil the snapshotter after use.

**Sources:** Apple `MKMapSnapshotter` docs.

---

## §6. MFMessageComposeViewController in SwiftUI

**Correct Pattern:**
```swift
struct MessageComposer: UIViewControllerRepresentable {
    let recipients: [String]; let body: String; let message: MSMessage?
    let onFinish: (MessageComposeResult) -> Void

    func makeCoordinator() -> C { C(onFinish: onFinish) }
    func makeUIViewController(context: Context) -> MFMessageComposeViewController {
        let vc = MFMessageComposeViewController()
        vc.messageComposeDelegate = context.coordinator
        vc.recipients = recipients
        vc.body = body
        if let message { vc.message = message }        // rich iMessage bubble
        return vc
    }
    func updateUIViewController(_ vc: MFMessageComposeViewController, context: Context) {}

    final class C: NSObject, MFMessageComposeViewControllerDelegate {
        let onFinish: (MessageComposeResult) -> Void
        init(onFinish: @escaping (MessageComposeResult) -> Void) { self.onFinish = onFinish }
        func messageComposeViewController(_ c: MFMessageComposeViewController,
                                          didFinishWith result: MessageComposeResult) {
            c.dismiss(animated: true)                  // the DELEGATE dismisses
            onFinish(result)
        }
    }
}
```

**Common Mistakes:**
```swift
// BROKEN: SwiftUI dismiss instead of the delegate → compose sheet hangs.
@Environment(\.dismiss) var dismiss
// ...didFinishWith: dismiss()   // wrong; controller wasn't presented by SwiftUI
```

**Gotchas:**
- `canSendText()` is `false` on Simulator, no-SIM devices, and under restrictions — gate the UI on it.
- Presenting the composer from inside an existing `.sheet` double-stacks presentations; present from the base view.

**iOS Version Notes:** Stable across 17→18; 26 unverified.

**Memory/Performance:** Negligible. Coordinator retains the delegate correctly.

**Sources:** Apple `MFMessageComposeViewController` docs.

---

## §7. SwiftUI TextField + Search

**Correct Pattern:**
```swift
@FocusState private var searchFocused: Bool
@State private var query = ""

TextField("Search spots", text: $query)
    .focused($searchFocused)
    .onChange(of: query) { _, new in debounce(new) }   // fires per keystroke
    .onSubmit { commitSearch(query) }                  // fires on return

// Debounce with a task:
@State private var searchTask: Task<Void, Never>?
func debounce(_ text: String) {
    searchTask?.cancel()
    searchTask = Task {
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else { return }
        completer.queryFragment = text                 // MKLocalSearchCompleter
    }
}
```

Focus only **after** expansion (see §4): set `searchFocused = true` in `didTransition(.expanded)`, never in compact.

**Common Mistakes:**
```swift
// BROKEN: focusing in compact — compact can't host a first responder.
searchFocused = true   // called while compact → nothing happens / glitches

// BROKEN: no debounce — a MKLocalSearch per keystroke, rate-limited and janky.
.onChange(of: query) { _, t in MKLocalSearch(...).start { } }
```

**Gotchas:**
- `.onChange` fires before `.onSubmit`. `.onSubmit` may not fire if focus is stolen first.
- `MKLocalSearchCompleter` for live suggestions (cheap); debounced `MKLocalSearch` for committed results (expensive). Two-stage state machine.
- Region-bias the completer to the map's region for relevant hits.

**iOS Version Notes:** `onChange` two-parameter form is iOS 17+. Older single-param is deprecated.

**Memory/Performance:** Cancel stale tasks or searches pile up. Matters in the extension.

**Sources:** Apple `MKLocalSearchCompleter`, `MKLocalSearch` docs.

---

## §8. SwiftUI Animations in Map Context

**Correct Pattern:**
```swift
withAnimation(.easeInOut(duration: 0.4)) { camera = .rect(fittedRect) }  // animates camera

Image(systemName: isActive ? "location.fill" : "location")
    .contentTransition(.symbolEffect(.replace))
    .symbolEffect(.pulse, isActive: isSearching)

.sensoryFeedback(.selection, trigger: selectedSpot)
```

**Common Mistakes:**
```swift
// BROKEN: matchedGeometryEffect across an unstable identity → snap/flicker.
// The id must be stable and the namespace shared; churn breaks it.
```

**Gotchas:**
- Heavy spring animations inside a scrolling list drop frames — prefer short `.easeInOut`.
- Animations can swallow map gesture recognizers mid-flight; keep camera animations short.

**iOS Version Notes:** `.symbolEffect` / `.sensoryFeedback` iOS 17+.

**Memory/Performance:** Fine in the host; keep minimal in the extension.

**Sources:** WWDC23 "Animate symbols in your app."

---

## §9. Contacts Framework (CNContact)

**Correct Pattern:**
```swift
let store = CNContactStore()
let granted = (try? await store.requestAccess(for: .contacts)) ?? false

switch CNContactStore.authorizationStatus(for: .contacts) {
case .authorized, .limited: /* fetch */ break
case .denied, .restricted:  /* show settings prompt */ break
case .notDetermined:        /* request */ break
@unknown default: break
}

let keys = [CNContactGivenNameKey, CNContactFamilyNameKey,
            CNContactPhoneNumbersKey] as [CNKeyDescriptor]
let req = CNContactFetchRequest(keysToFetch: keys)
try store.enumerateContacts(with: req) { contact, _ in /* on a background queue */ }
```

**Common Mistakes:**
```swift
// BROKEN: missing NSContactsUsageDescription in Info.plist → hard crash on request.
```

**Gotchas:**
- `enumerateContacts` blocks — run it off the main thread.
- iOS 18+ adds `.limited` authorization; handle it or you'll mis-branch.
- `CNContactPickerViewController` needs **no** permission (system-owned UI) — prefer it when you just need a picker.

**iOS Version Notes:** `.limited` is iOS 18+. Crash-without-usage-string is all versions.

**Memory/Performance:** Large address books — fetch minimal keys, lazy-render the list.

**Sources:** Apple `CNContactStore` docs.

---

## §10. App Group UserDefaults Cross-Process Sync

**Correct Pattern:**
```swift
let defaults = UserDefaults(suiteName: "group.com.kavigandham.tween")!
defaults.set(try JSONEncoder().encode(snapshot), forKey: "meetup")   // Data blob
// Reader polls ~300ms; single-key write is atomic.
```

**Common Mistakes:**
```swift
// BROKEN: relying on didChangeNotification across processes — it does NOT fire
// reliably app↔extension. Poll instead.
NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification ...)
```

**Gotchas:**
- `UserDefaults(suiteName:)` returns `nil` / empty if the App Group entitlement is missing or misspelled on either target.
- Cross-process change notifications are unreliable — **polling (~300 ms) is what actually works.**
- Simultaneous writes to one key: last-write-wins, no merge.

**iOS Version Notes:** Consistent across versions.

**Memory/Performance:** 300 ms polling of a small blob is cheap. Don't poll huge payloads.

**Sources:** Apple `UserDefaults` docs; App Group entitlement guide.

---

## §11. Dark Mode + Dynamic Type

**Correct Pattern:**
```swift
Color(.label); Color(.systemBackground); Color(.secondaryLabel)   // adaptive

let accent = Color(uiColor: UIColor { traits in
    traits.userInterfaceStyle == .dark ? .systemTeal : .systemBlue
})

Text("Spot").font(.body)          // scales with Dynamic Type
@ScaledMetric var iconSize = 24   // scales non-text values
```

**Common Mistakes:**
```swift
Color(red: 0.05, green: 0.05, blue: 0.1)   // fixed hex — invisible in dark mode
Font.system(size: 17)                       // does NOT scale with Dynamic Type
```

**Gotchas:**
- Semantic colors adapt automatically; hardcoded hex does not.
- `.font(.body)` scales; `.font(.system(size:))` is fixed.
- Test both schemes in previews (`.preferredColorScheme`) and Dynamic Type at XXL for clipping.

**iOS Version Notes:** Consistent 17→18; 26 unverified.

**Memory/Performance:** None.

**Sources:** Apple HIG — Color, Typography.

---

## §12. iMessage Extension Sizing

**Correct Pattern:**
- **Compact** ≈ keyboard height; varies by device. Treat as small and fixed — no keyboard, no first responder here (§7).
- **Expanded** ≈ full screen minus safe-area insets. Size is only final in `didTransition(to:)` (§4).
- Do all keyboard/search/map interaction in expanded.

**Common Mistakes:**
```swift
// BROKEN: reading view.bounds in willBecomeActive to lay out expanded UI —
// not sized yet. Read in didTransition.
```

**Gotchas:**
- `.presentationDetents` do **not** apply inside the extension — you don't own that presentation.
- `preferredContentSize` is largely ignored by the Messages host.
- The extension gets a system container, not your own navigation controller.

**iOS Version Notes:** Sizing timing stable 17→18; 26 unverified.

**Memory/Performance:** Expanded + live Map is where the 120 MB ceiling bites — snapshot instead (§5).

**Sources:** Apple `MSMessagesAppViewController` presentation-style docs.

---

*iOS 26 notes are provisional — verify on-device via Madhav before relying on them.*
