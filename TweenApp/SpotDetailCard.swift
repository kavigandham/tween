import SwiftUI
import MapKit
import CoreLocation
import UIKit

/// The detail card shown when a user taps a search result. It surfaces the
/// spot's name, address, an optional fairness ETA chip, and a small map
/// thumbnail, then offers the primary "Send to chat" hand-off plus secondary
/// deep links into Apple Maps and Google Maps.
struct SpotDetailCard: View {
    let name: String
    let address: String?
    let coordinate: CLLocationCoordinate2D
    /// Present only when the spot was fairness-ranked (both coordinates known).
    let ranked: RankedSpot?
    var onSendToChat: () -> Void

    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    thumbnail
                    info
                    secondaryButtons
                }
                .padding(20)
            }
            sendButton
                .padding(20)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    // MARK: - Sections

    private var header: some View {
        HStack {
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding([.top, .horizontal], 16)
    }

    private var thumbnail: some View {
        TweenMapSnapshotView(
            markers: [MapMarker(coordinate: coordinate, role: .midpoint)],
            cornerRadius: 16
        )
        .frame(width: 200, height: 150)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(name)
                .font(.title2.weight(.semibold))
                .lineLimit(2)
            if let address, !address.isEmpty {
                Text(address)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if let ranked {
                ETAChip(etaFromA: ranked.etaFromA, etaFromB: ranked.etaFromB)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var secondaryButtons: some View {
        HStack(spacing: 12) {
            Button {
                if let url = appleMapsURL { openURL(url) }
            } label: {
                Label("Apple Maps", systemImage: "map")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            Button {
                if let url = googleMapsURL { openURL(url) }
            } label: {
                Label("Google Maps", systemImage: "globe")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        .controlSize(.large)
    }

    private var sendButton: some View {
        Button {
            onSendToChat()
            dismiss()
        } label: {
            Label("Send to chat", systemImage: "paperplane.fill")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
    }

    // MARK: - Deep links

    /// `http://maps.apple.com/?ll=LAT,LON&q=NAME` — opens the native Maps app.
    private var appleMapsURL: URL? {
        let q = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "Spot"
        return URL(string: "http://maps.apple.com/?ll=\(coordinate.latitude),\(coordinate.longitude)&q=\(q)")
    }

    /// `comgooglemaps://?q=LAT,LON` — opens Google Maps when installed.
    private var googleMapsURL: URL? {
        URL(string: "comgooglemaps://?q=\(coordinate.latitude),\(coordinate.longitude)")
    }
}

#Preview {
    SpotDetailCard(
        name: "Blue Bottle Coffee",
        address: "66 Mint St, San Francisco",
        coordinate: CLLocationCoordinate2D(latitude: 37.7825, longitude: -122.4099),
        ranked: RankedSpot(item: nil, etaFromA: 540, etaFromB: 600, confidence: 1.0),
        onSendToChat: {}
    )
}
