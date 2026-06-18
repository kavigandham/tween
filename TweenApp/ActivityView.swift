import SwiftUI
import UIKit

/// A thin SwiftUI wrapper around `UIActivityViewController` so an invite text
/// (or anything shareable) can be presented through the standard system share
/// sheet via `.sheet`.
struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
