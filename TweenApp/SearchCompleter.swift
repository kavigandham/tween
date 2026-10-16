import Foundation
import MapKit
import CoreLocation
import SwiftUI
import UIKit

/// The live text in the search field.
///
/// A reference type, NOT a `@State` on `OnboardingView`: every keystroke
/// writes it, and a `@State` write invalidates that view's WHOLE body — the
/// Map and every annotation, the group bar, the banners, the result cards and
/// both tour overlay layers — once per character (measured: 6 keystrokes = 6
/// full home-screen passes, lag audit 2026-10-15). `@Observable` tracks reads
/// per property, so only the small view that actually renders the text
/// re-renders. Same rule and same reason as `SheetEdgeTracker`: a value
/// written on every frame of an interaction lives in a reference type read
/// ONLY by the view that needs it.
///
/// Never read `value` from a view body that isn't the search row itself —
/// doing so re-registers the whole screen as a dependency and puts the lag
/// straight back. The action paths (`commitSearch`, `clearSearch`, …) read it
/// through `OnboardingView.searchText`, which is safe because those run
/// outside body evaluation.
@Observable final class SearchFieldText {
    var value: String = ""
}

/// The Apple-Maps search row: the native field plus whatever sits in the
/// avatar slot beside it (the Friends circle).
///
/// Its own view so a keystroke re-renders THIS and nothing else. The
/// query-change handler lives here rather than on the home screen for the
/// same reason: `onChange(of:)` reads the value it watches, and reading it up
/// there is exactly the dependency this split exists to remove.
struct SearchFieldRow<Trailing: View>: View {
    @Bindable var field: SearchFieldText
    @Binding var isEditing: Bool
    var placeholder: String
    var onSubmit: () -> Void
    var onQueryChange: (String) -> Void
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: Tokens.Spacing.s2) {
            NativeSearchBar(text: $field.value,
                            isEditing: $isEditing,
                            placeholder: placeholder,
                            onSubmit: onSubmit)
                .frame(minHeight: Tokens.Layout.searchBarHeight)
                .onChange(of: field.value) { _, query in onQueryChange(query) }

            trailing
        }
    }
}

/// The real UIKit `UISearchBar` bridged into SwiftUI.
///
/// Same technique as the community "missing UISearchBar" wrappers on the
/// github.com/topics/uisearchbar list (SearchBarView, SearchBarSwiftUI):
/// a `UIViewRepresentable` around the native component rather than a
/// hand-rolled lookalike — so the field's chrome (inset fill, magnifier,
/// clear button, Dynamic Type, dark mode) is pixel-identical to Apple Maps
/// with zero third-party code (hard project constraint: no dependencies).
/// Host app only; the extension's compact surface must never show a keyboard.
struct NativeSearchBar: UIViewRepresentable {
    @Binding var text: String
    /// Two-way focus: the delegate reports begin/end editing, and setting it
    /// from SwiftUI (commitSearch, expand-then-focus) moves first responder.
    @Binding var isEditing: Bool
    var placeholder: String
    var onSubmit: () -> Void

    func makeUIView(context: Context) -> UISearchBar {
        let bar = UISearchBar()
        bar.searchBarStyle = .minimal   // just the field, no outer chrome
        bar.placeholder = placeholder
        // Autocorrect stays ON: Apple's server-side correction misses typos
        // that collide with real place names ("shushi" → Shusha, Azerbaijan;
        // probed 2026-07-31), so the keyboard fixing the word before it's
        // ever committed is the strongest typo defense we have.
        bar.autocorrectionType = .default
        bar.returnKeyType = .search
        bar.delegate = context.coordinator
        bar.setContentHuggingPriority(.defaultLow, for: .horizontal)
        bar.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // Dynamic Type: the plain UISearchBar text field doesn't scale on its
        // own (audit — last open item). Anchor it to the .body metric and let
        // it track the content-size category so the field grows with the
        // user's text size instead of staying pinned at the default.
        bar.searchTextField.font = .preferredFont(forTextStyle: .body)
        bar.searchTextField.adjustsFontForContentSizeCategory = true
        return bar
    }

    func updateUIView(_ bar: UISearchBar, context: Context) {
        context.coordinator.parent = self
        if bar.text != text { bar.text = text }
        // Focus follows the EDGES of the SwiftUI intent, not its level.
        // Re-asserting first responder on every SwiftUI update meant an
        // interactive keyboard dismissal mid-drag summoned the keyboard
        // right back while `isEditing` was still true — the field fought
        // the sheet drag for the gesture (device feedback: clunky drags
        // whenever the field had text).
        let wasEditing = context.coordinator.appliedEditing
        if isEditing, !wasEditing {
            // Latch only when the edge was actually APPLIED: consuming it
            // while the bar is off-window (first update runs before window
            // attach) would silently eat the focus request and the keyboard
            // would never appear until focus toggled again.
            if bar.window != nil {
                context.coordinator.appliedEditing = true
                // One run-loop turn later, NOT inside this update: a
                // responder change here runs the delegate's begin/end-editing
                // callbacks — which write `isEditing` back — while SwiftUI is
                // still applying the update that asked for it. Every
                // programmatic focus drop (peek settle, suggestion tap,
                // commit) logged ~20 "AttributeGraph: cycle detected" breaks,
                // each one a dependency SwiftUI had to sever mid-frame
                // (measured 2026-09-05).
                DispatchQueue.main.async {
                    if !bar.isFirstResponder { bar.becomeFirstResponder() }
                }
            }
        } else if !isEditing, wasEditing {
            context.coordinator.appliedEditing = false
            DispatchQueue.main.async {
                if bar.isFirstResponder { bar.resignFirstResponder() }
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UISearchBarDelegate {
        var parent: NativeSearchBar
        /// The `isEditing` value the last `updateUIView` acted on — focus
        /// moves only when SwiftUI's intent CHANGES (see updateUIView).
        var appliedEditing = false
        init(_ parent: NativeSearchBar) { self.parent = parent }

        func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
            parent.text = searchText
        }

        func searchBarTextDidBeginEditing(_ searchBar: UISearchBar) {
            parent.isEditing = true
        }

        func searchBarTextDidEndEditing(_ searchBar: UISearchBar) {
            parent.isEditing = false
        }

        func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
            parent.onSubmit()
        }
    }
}

/// Live search-suggestion source backing the search bar's "while typing" state.
///
/// Wraps `MKLocalSearchCompleter` — which is delegate-based and, unlike a full
/// `MKLocalSearch`, only resolves lightweight name/address completions — and
/// republishes its completions as observable state for SwiftUI. This is the host
/// app only; the extension never offers typed suggestions.
@Observable
final class SearchCompleter: NSObject, MKLocalSearchCompleterDelegate {
    /// Where the current completion request stands, so the UI can tell
    /// "still searching" from "nothing matched" from "MapKit failed" —
    /// without this, the failure path just emptied `results` and the
    /// suggestions list spun "Searching nearby..." forever (audit W16).
    enum Phase { case idle, searching, resolved, failed }

    /// The current suggestions for the typed query, screened against the
    /// meetup area — the completer's `region` is only a bias, and a query
    /// with no local footprint fills the dropdown with global name matches
    /// ("shushi" → Shusha, Azerbaijan; probed 2026-07-31).
    private(set) var results: [MKLocalSearchCompletion] = []
    private(set) var phase: Phase = .idle

    private let completer = MKLocalSearchCompleter()

    /// Address tokens ("TX" / "United States") for the current search-region
    /// center, resolved by ONE reverse-geocode and cached per rounded center.
    /// Nil until the first geocode lands — suggestions pass unfiltered then.
    private var regionTokens: CompletionRegionTokens?
    private var regionTokensKey: String?
    /// The center currently being reverse-geocoded — guards against firing a
    /// new lookup per keystroke while one is already in flight.
    private var pendingTokensKey: String?
    private let geocoder = CLGeocoder()

    /// Timer for the debounced entry point. Cancelled and re-armed on every
    /// keystroke so the completer only sees the query the user paused on,
    /// not every intermediate character. See `debouncedUpdate(query:region:)`
    /// and `docs/ui-research.md` §7.
    private var debounceTask: Task<Void, Never>?

    /// Default debounce window for keystroke-driven completer updates.
    /// 300 ms matches the search-task debounce elsewhere in the app and is
    /// the value recommended by `docs/ui-research.md` §7.
    private static let defaultDebounceMs: UInt64 = 300

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.pointOfInterest, .address]
    }

    /// Feeds the latest query fragment to the completer. An empty query clears
    /// suggestions without hitting the network. Biases results toward `region`
    /// (the meetup midpoint) when one is supplied.
    func update(query: String, region: MKCoordinateRegion? = nil) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            results = []
            phase = .idle
            completer.queryFragment = ""
            return
        }
        phase = .searching
        if let region {
            completer.region = region
            resolveRegionTokensIfNeeded(for: region)
        }
        completer.queryFragment = trimmed
    }

    /// One reverse-geocode per (rounded) region center, feeding the
    /// suggestion filter. The resolved key is latched only on SUCCESS — a
    /// failed lookup (rate limit, offline) retries on the next keystroke
    /// instead of pinning stale tokens forever; while the region has moved
    /// but tokens haven't resolved, the filter passes everything through
    /// rather than filtering against the previous region (post-push audit m3).
    private func resolveRegionTokensIfNeeded(for region: MKCoordinateRegion) {
        let key = String(format: "%.2f,%.2f", region.center.latitude, region.center.longitude)
        guard key != regionTokensKey, key != pendingTokensKey else { return }
        pendingTokensKey = key
        // Drop BOTH the stale tokens and their key: keeping the old key made
        // a later return to that region early-out with tokens still nil when
        // the new region's geocode had failed (delta audit finding 6).
        if regionTokensKey != nil {
            regionTokens = nil
            regionTokensKey = nil
        }
        let location = CLLocation(latitude: region.center.latitude,
                                  longitude: region.center.longitude)
        Task { @MainActor [weak self] in
            guard let self else { return }
            let placemark = try? await self.geocoder.reverseGeocodeLocation(location).first
            guard self.pendingTokensKey == key else { return }
            self.pendingTokensKey = nil
            guard let placemark else { return }
            self.regionTokensKey = key
            self.regionTokens = CompletionRegionTokens(
                administrativeArea: placemark.administrativeArea,
                country: placemark.country)
        }
    }

    /// Debounced variant of `update(query:region:)`. Cancels any in-flight
    /// keystroke timer and schedules a fresh one so `MKLocalSearchCompleter`
    /// only sees the query the user paused on. An empty query clears
    /// immediately — no debounce delay on the "user wiped the field" gesture.
    /// Per `docs/ui-research.md` §7.
    @MainActor
    func debouncedUpdate(query: String, region: MKCoordinateRegion? = nil,
                         debounceMs: UInt64 = SearchCompleter.defaultDebounceMs) {
        debounceTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            update(query: "", region: region)
            return
        }
        // The spinner must be honest during the debounce window too.
        phase = .searching
        debounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: debounceMs * 1_000_000)
            guard !Task.isCancelled else { return }
            self?.update(query: trimmed, region: region)
        }
    }

    // MARK: - MKLocalSearchCompleterDelegate

    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        // Pass the typed query so a place the user NAMED (a distant city they
        // spelled out) survives the region screen, and so the screen never
        // empties the dropdown when nothing local matches. See CompletionRegionFilter.
        results = CompletionRegionFilter.filter(
            completer.results, tokens: regionTokens, query: completer.queryFragment)
        phase = .resolved
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        results = []
        phase = .failed
    }
}
