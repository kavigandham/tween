import Foundation
import MapKit
import SwiftUI
import UIKit

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
        bar.autocorrectionType = .no
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
        if isEditing, !bar.isFirstResponder, bar.window != nil {
            bar.becomeFirstResponder()
        } else if !isEditing, bar.isFirstResponder {
            bar.resignFirstResponder()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UISearchBarDelegate {
        var parent: NativeSearchBar
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

    /// The current suggestions for the typed query.
    private(set) var results: [MKLocalSearchCompletion] = []
    private(set) var phase: Phase = .idle

    private let completer = MKLocalSearchCompleter()

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
        if let region { completer.region = region }
        completer.queryFragment = trimmed
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
        results = completer.results
        phase = .resolved
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        results = []
        phase = .failed
    }
}
