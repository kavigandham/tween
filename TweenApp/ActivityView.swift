import SwiftUI
import UIKit

/// A thin SwiftUI wrapper around `UIActivityViewController` so an invite text
/// (or anything shareable) can be presented through the standard system share
/// sheet via `.sheet`.
struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]
    /// Fires when the share sheet is dismissed (shared or cancelled) so the
    /// presenter can reset its sheet state — otherwise the binding stays set and
    /// the invite can't be reopened.
    var onComplete: () -> Void = {}

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in onComplete() }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
