import SwiftUI
import MapKit
import CoreLocation

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

#Preview {
    List {
        ResultRow(name: "Blue Bottle Coffee", address: "66 Mint St, San Francisco")
        RankedResultRow(spot: RankedSpot(item: nil, etaFromA: 600, etaFromB: 540, confidence: 1.0))
        RankedResultRow(spot: RankedSpot(item: nil, etaFromA: 600, etaFromB: 900, confidence: 1.0))
        RankedResultRow(spot: RankedSpot(item: nil, etaFromA: 300, etaFromB: 1200, confidence: 0.5))
    }
}
