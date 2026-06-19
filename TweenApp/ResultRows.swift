import SwiftUI
import MapKit
import CoreLocation
import UIKit

/// A plain place row: category-style icon, name, and address. Used for search
/// hits before two coordinates exist (no ETAs to show yet).
struct ResultRow: View {
    let name: String
    let address: String?
    var icon: String = "mappin.circle.fill"

    var body: some View {
        HStack(spacing: Tokens.Spacing.s3) {
            Image(systemName: icon)
                .font(Tokens.Typography.title2)
                .foregroundStyle(Tokens.Palette.brand)
                .frame(width: Tokens.Spacing.s7)
            VStack(alignment: .leading, spacing: Tokens.Spacing.s1) {
                Text(name)
                    .font(Tokens.Typography.headline)
                    .lineLimit(1)
                if let address, !address.isEmpty {
                    Text(address)
                        .font(Tokens.Typography.caption)
                        .foregroundStyle(Tokens.Palette.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

/// A dual-pill badge showing both drive times, tinted by how lopsided the trip
/// is: green under 3 min apart, yellow 3–8, orange beyond.
struct ETAChip: View {
    let etaFromA: TimeInterval
    let etaFromB: TimeInterval

    private var gapMinutes: Double { abs(etaFromA - etaFromB) / 60 }

    private var tint: Color {
        switch gapMinutes {
        case ..<3:  return Tokens.Palette.fairnessGood
        case 3...8: return Tokens.Palette.fairnessOkay
        default:    return Tokens.Palette.fairnessPoor
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            minutes(etaFromA)
            Text("|")
                .foregroundStyle(Tokens.Palette.textSecondary)
                .padding(.horizontal, Tokens.Spacing.s2)
            minutes(etaFromB)
        }
        .font(Tokens.Typography.captionBold.monospacedDigit())
        .padding(.horizontal, Tokens.Spacing.s3)
        .padding(.vertical, Tokens.Spacing.s2)
        .background(tint.opacity(0.18), in: Capsule())
        .foregroundStyle(tint)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Drive times")
        .accessibilityValue("\(mins(etaFromA)) minutes for you, \(mins(etaFromB)) minutes for your friend")
    }

    private func minutes(_ eta: TimeInterval) -> some View {
        Text("\(mins(eta)) min")
    }

    private func mins(_ eta: TimeInterval) -> Int { Int((eta / 60).rounded()) }
}

/// A compact "A … · B …" capsule comparing the two participants' trips to a
/// spot. A is the current user, B is the friend. Shows real drive times when the
/// spot has been fairness-ranked, otherwise straight-line distance; either side
/// reads "--" when that coordinate is unknown.
struct ABDistanceLabel: View {
    let selfCoord: CLLocationCoordinate2D?
    let peerCoord: CLLocationCoordinate2D?
    let target: CLLocationCoordinate2D
    var ranked: RankedSpot?

    var body: some View {
        HStack(spacing: Tokens.Spacing.s1) {
            Text("A \(aValue)")
            Text("·").foregroundStyle(Tokens.Palette.textSecondary)
            Text("B \(bValue)")
        }
        .font(Tokens.Typography.captionBold.monospacedDigit())
        .padding(.horizontal, Tokens.Spacing.s2)
        .padding(.vertical, Tokens.Spacing.s1)
        .background(.ultraThinMaterial, in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("You \(aValue), your friend \(bValue)")
    }

    private var aValue: String {
        if let ranked { return Self.formatETA(ranked.etaFromA) }
        return Self.formatDistance(from: selfCoord, to: target)
    }

    private var bValue: String {
        if let ranked { return Self.formatETA(ranked.etaFromB) }
        return Self.formatDistance(from: peerCoord, to: target)
    }

    /// Straight-line miles between two coordinates; "--" when the origin is
    /// unknown, "nearby" under a tenth of a mile.
    static func formatDistance(from: CLLocationCoordinate2D?, to: CLLocationCoordinate2D) -> String {
        guard let from else { return "--" }
        let a = CLLocation(latitude: from.latitude, longitude: from.longitude)
        let b = CLLocation(latitude: to.latitude, longitude: to.longitude)
        let miles = a.distance(from: b) / 1609.34
        if miles < 0.1 { return "nearby" }
        return String(format: "%.1f mi", miles)
    }

    /// A driving ETA in seconds as a short string: "<1 min" / "N min" / "Nh Mm".
    static func formatETA(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes < 1 { return "<1 min" }
        if minutes < 60 { return "\(minutes) min" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }
}

/// A ranked place row: the place's name and address with its dual-ETA chip on
/// the trailing edge.
struct RankedResultRow: View {
    let spot: RankedSpot

    var body: some View {
        HStack(spacing: Tokens.Spacing.s3) {
            ResultRow(name: spot.item?.name ?? "Spot",
                      address: spot.item?.placemark.title)
            Spacer(minLength: Tokens.Spacing.s2)
            ETAChip(etaFromA: spot.etaFromA, etaFromB: spot.etaFromB)
        }
    }
}

/// A compact suggestion row shown *while the user is still typing*, backed by
/// `MKLocalSearchCompleter`. Deliberately lighter than `ResultCard` so search
/// suggestions read as a different surface from committed results.
struct SuggestionRow: View {
    let completion: MKLocalSearchCompletion

    var body: some View {
        HStack(spacing: Tokens.Spacing.s3) {
            Image(systemName: "mappin.circle.fill")
                .font(Tokens.Typography.title2)
                .foregroundStyle(Tokens.Palette.textSecondary)
                .frame(width: Tokens.Spacing.s8)
            VStack(alignment: .leading, spacing: Tokens.Spacing.s1) {
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
            Spacer(minLength: 0)
            Image(systemName: "arrow.up.left")
                .font(Tokens.Typography.caption)
                .foregroundStyle(Tokens.Palette.textTertiary)
        }
        .padding(.vertical, Tokens.Spacing.s2)
        .frame(minHeight: Tokens.Layout.minTapTarget)
        .contentShape(Rectangle())
    }
}

/// A rich result card shown in the *committed* search results list (after the
/// user presses Enter or taps a suggestion) — visually distinct from the compact
/// `SuggestionRow`. Surfaces the place name, category, distance, address, an
/// optional fairness ETA chip, and the primary actions: Directions, Call (when a
/// number is on file), and Send to chat.
struct ResultCard: View {
    let item: MKMapItem
    let rankedSpot: RankedSpot?
    let userCoord: CLLocationCoordinate2D?
    let onDirections: () -> Void
    let onSendToChat: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s2) {
            Text(item.name ?? "Unknown")
                .font(Tokens.Typography.title2.weight(.semibold))
                .lineLimit(1)

            if let category = item.pointOfInterestCategory?.displayName {
                Text(category)
                    .font(Tokens.Typography.callout)
                    .foregroundStyle(Tokens.Palette.textSecondary)
            }

            HStack(spacing: Tokens.Spacing.s2) {
                if let distanceString {
                    Text(distanceString)
                        .font(Tokens.Typography.callout)
                        .foregroundStyle(Tokens.Palette.brand)
                }
                if let address = item.placemark.title, !address.isEmpty {
                    Text(address)
                        .font(Tokens.Typography.caption)
                        .foregroundStyle(Tokens.Palette.textSecondary)
                        .lineLimit(1)
                }
            }

            if let rankedSpot {
                ETAChip(etaFromA: rankedSpot.etaFromA, etaFromB: rankedSpot.etaFromB)
            }

            HStack(spacing: Tokens.Spacing.s2) {
                Button(action: onDirections) {
                    Label("Directions", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                }
                .buttonStyle(.resultAction(.subtle))
                .accessibilityHint("Opens \(item.name ?? "this place") in Apple Maps")

                if let phone = item.phoneNumber, !phone.isEmpty {
                    Button {
                        let digits = phone.filter { !$0.isWhitespace }
                        if let url = URL(string: "tel:\(digits)") {
                            UIApplication.shared.open(url)
                        }
                    } label: {
                        Label("Call", systemImage: "phone.fill")
                    }
                    .buttonStyle(.resultAction(.subtle))
                    .accessibilityHint("Calls \(item.name ?? "this place")")
                }

                Button(action: onSendToChat) {
                    Label("Send", systemImage: "paperplane.fill")
                }
                .buttonStyle(.resultAction())
                .accessibilityHint("Sends this spot to your chat")
            }
        }
        .padding(Tokens.Spacing.s4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.Palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.card))
        .tweenElevation(.floating)
    }

    /// Straight-line miles from the user to the spot; nil when we don't yet know
    /// where the user is.
    private var distanceString: String? {
        guard let userCoord else { return nil }
        let from = CLLocation(latitude: userCoord.latitude, longitude: userCoord.longitude)
        let to = CLLocation(latitude: item.placemark.coordinate.latitude,
                            longitude: item.placemark.coordinate.longitude)
        return String(format: "%.1f mi", from.distance(from: to) / 1609.34)
    }
}

/// Compact action pills for result cards. The global Tween primary style is
/// intentionally broad for full-width CTAs; search rows need denser controls.
struct ResultActionButtonStyle: ButtonStyle {
    enum Variant {
        case prominent
        case subtle
    }

    var variant: Variant = .prominent

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Tokens.Typography.subheadline.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, Tokens.Spacing.s3)
            .padding(.vertical, Tokens.Spacing.s2)
            .background(background, in: Capsule())
            .foregroundStyle(foreground)
            .tweenPressFeedback(isPressed: configuration.isPressed)
    }

    private var foreground: Color {
        switch variant {
        case .prominent: return .white
        case .subtle:    return Tokens.Palette.brand
        }
    }

    private var background: AnyShapeStyle {
        switch variant {
        case .prominent: return AnyShapeStyle(Tokens.Palette.brand)
        case .subtle:    return AnyShapeStyle(Tokens.Palette.brandLight)
        }
    }
}

extension ButtonStyle where Self == ResultActionButtonStyle {
    static func resultAction(_ variant: ResultActionButtonStyle.Variant = .prominent) -> ResultActionButtonStyle {
        ResultActionButtonStyle(variant: variant)
    }
}

/// Human-readable label for the common point-of-interest categories Tween shows;
/// nil for anything we don't have a friendly name for (the card then omits the
/// category line entirely).
extension MKPointOfInterestCategory {
    var displayName: String? {
        switch self {
        case .restaurant:    return "Restaurant"
        case .cafe:          return "Cafe"
        case .bakery:        return "Bakery"
        case .store:         return "Store"
        case .gasStation:    return "Gas Station"
        case .park:          return "Park"
        case .nightlife:     return "Nightlife"
        case .theater:       return "Theater"
        case .fitnessCenter: return "Fitness"
        default:             return nil
        }
    }
}

#Preview {
    List {
        ResultRow(name: "Blue Bottle Coffee", address: "66 Mint St, San Francisco")
        RankedResultRow(spot: RankedSpot(item: nil, etaFromA: 600, etaFromB: 540, confidence: 1.0))
        RankedResultRow(spot: RankedSpot(item: nil, etaFromA: 600, etaFromB: 900, confidence: 1.0))
        RankedResultRow(spot: RankedSpot(item: nil, etaFromA: 300, etaFromB: 1200, confidence: 0.5))
    }
}
