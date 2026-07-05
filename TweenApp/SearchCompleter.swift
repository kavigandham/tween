import Foundation
import MapKit

/// Live search-suggestion source backing the search bar's "while typing" state.
///
/// Wraps `MKLocalSearchCompleter` — which is delegate-based and, unlike a full
/// `MKLocalSearch`, only resolves lightweight name/address completions — and
/// republishes its completions as observable state for SwiftUI. This is the host
/// app only; the extension never offers typed suggestions.
@Observable
final class SearchCompleter: NSObject, MKLocalSearchCompleterDelegate {
    /// The current suggestions for the typed query.
    private(set) var results: [MKLocalSearchCompletion] = []

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
            completer.queryFragment = ""
            return
        }
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
        debounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: debounceMs * 1_000_000)
            guard !Task.isCancelled else { return }
            self?.update(query: trimmed, region: region)
        }
    }

    // MARK: - MKLocalSearchCompleterDelegate

    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        results = completer.results
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        results = []
    }
}
