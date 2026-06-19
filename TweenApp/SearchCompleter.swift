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

    // MARK: - MKLocalSearchCompleterDelegate

    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        results = completer.results
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        results = []
    }
}
