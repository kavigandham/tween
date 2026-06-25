import SwiftUI
import MapKit
import CoreLocation
import UIKit

/// The detail card shown when a user taps a search result OR receives an
/// incoming Tween-link spot from a friend. Surfaces the spot's name, address,
/// optional fairness ETA chip, and a map thumbnail.
///
/// Behaviour switches on `incoming`:
/// - `incoming == nil` → "Send to chat" button (user picked this spot from
///   their own search and wants to share it with a friend).
/// - `incoming != nil` → an incoming proposal from a friend; renders an
///   **Agree** button (sends a reply bubble) and a **Change** button (lets
///   the user pick a different spot). The original Send-to-chat CTA is hidden.
struct SpotDetailCard: View {
    let name: String
    let address: String?
    let coordinate: CLLocationCoordinate2D
    /// Present only when the spot was fairness-ranked (both coordinates known).
    let ranked: RankedSpot?
    /// When set, this card represents a proposal received via `tween://` link
    /// (i.e. from a friend's "Send to friends" SMS). Switches the CTAs from
    /// "Send to chat" to "Agree" / "Change".
    var incoming: IncomingProposal? = nil
    var onSendToChat: () -> Void = {}
    var onAgree: () -> Void = {}
    var onChange: () -> Void = {}

    /// Metadata for an incoming proposal. Drives the headline + per-message-
    /// type copy variations (a counter reads "suggests instead" rather than
    /// "suggests").
    struct IncomingProposal {
        let senderName: String?
        /// True when the link is a counter-proposal (overrides a previous
        /// agreement); shifts the headline copy.
        let isCounter: Bool
    }

    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss

    /// Bumped on send so the CTA can fire an impact haptic.
    @State private var sendTick = 0

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: Tokens.Spacing.s4) {
                    if let incoming { incomingHeadline(incoming) }
                    thumbnail
                    info
                    secondaryButtons
                }
                .padding(Tokens.Spacing.s5)
            }
            primaryActions
                .padding(Tokens.Spacing.s5)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    /// Shown above the spot info when this card represents an incoming
    /// proposal from a friend, so the user understands they're being asked
    /// to respond — not browsing a search result they picked themselves.
    private func incomingHeadline(_ proposal: IncomingProposal) -> some View {
        let who = proposal.senderName ?? "Your friend"
        let verb = proposal.isCounter ? "suggests instead" : "suggests"
        return VStack(alignment: .leading, spacing: Tokens.Spacing.s1) {
            Text("\(who) \(verb)")
                .font(Tokens.Typography.callout)
                .foregroundStyle(Tokens.Palette.textSecondary)
            Text("Do you want to agree or change it?")
                .font(Tokens.Typography.subheadline)
                .foregroundStyle(Tokens.Palette.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Sections

    private var header: some View {
        HStack {
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(Tokens.Typography.title2)
                    .foregroundStyle(Tokens.Palette.textSecondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
        .padding([.top, .horizontal], Tokens.Spacing.s4)
    }

    private var thumbnail: some View {
        TweenMapSnapshotView(
            markers: [MapMarker(coordinate: coordinate, role: .fairSpot)],
            cornerRadius: Tokens.Radius.card
        )
        .frame(width: 200, height: 150)
        .frame(maxWidth: .infinity, alignment: .center)
        .accessibilityLabel("Map showing \(name)")
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s2) {
            Text(name)
                .font(Tokens.Typography.title2.weight(.semibold))
                .lineLimit(2)
            if let address, !address.isEmpty {
                Text(address)
                    .font(Tokens.Typography.subheadline)
                    .foregroundStyle(Tokens.Palette.textSecondary)
            }
            if let ranked {
                ETAChip(etaFromA: ranked.etaFromA, etaFromB: ranked.etaFromB)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var secondaryButtons: some View {
        HStack(spacing: Tokens.Spacing.s3) {
            Button {
                if let url = appleMapsURL { openURL(url) }
            } label: {
                Label("Apple Maps", systemImage: "map")
            }
            .buttonStyle(.tweenPrimary(.subtle))
            .accessibilityHint("Opens \(name) in Apple Maps")

            Button {
                if let url = googleMapsURL { openURL(url) }
            } label: {
                Label("Google Maps", systemImage: "globe")
            }
            .buttonStyle(.tweenPrimary(.subtle))
            .accessibilityHint("Opens \(name) in Google Maps")
        }
    }

    /// Either the original "Send to chat" CTA for self-picked spots, OR an
    /// Agree / Change pair when this card represents an incoming proposal.
    @ViewBuilder
    private var primaryActions: some View {
        if incoming != nil {
            HStack(spacing: Tokens.Spacing.s2) {
                Button {
                    sendTick += 1
                    onAgree()
                    dismiss()
                } label: {
                    Label("Agree", systemImage: "checkmark.circle.fill")
                        .lineLimit(1)
                }
                .buttonStyle(.tweenPrimary())
                .accessibilityHint("Sends back a reply that you agree to meet at \(name)")

                Button {
                    sendTick += 1
                    onChange()
                    dismiss()
                } label: {
                    Label("Change", systemImage: "arrow.triangle.2.circlepath")
                        .lineLimit(1)
                }
                .buttonStyle(.tweenPrimary(.subtle))
                .accessibilityHint("Opens search to pick a different spot")
            }
            .sensoryFeedback(.impact, trigger: sendTick)
        } else {
            Button {
                sendTick += 1
                onSendToChat()
                dismiss()
            } label: {
                Label("Send to chat", systemImage: "paperplane.fill")
            }
            .buttonStyle(.tweenPrimary())
            .sensoryFeedback(.impact, trigger: sendTick)
            .accessibilityHint("Drops \(name) into your conversation")
        }
    }

    // MARK: - Deep links

    /// `http://maps.apple.com/?ll=LAT,LON&q=NAME` — opens the native Maps app.
    private var appleMapsURL: URL? {
        MapLinks.appleMapsURL(name: name, coordinate: coordinate)
    }

    /// `comgooglemaps://?q=NAME&center=LAT,LON` — opens Google Maps when installed.
    private var googleMapsURL: URL? {
        MapLinks.googleMapsURL(name: name, coordinate: coordinate)
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
