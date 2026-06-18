import SwiftUI
import MapKit

/// A plain place row: category-style icon, name, and address. Used for search
/// hits before two coordinates exist (no ETAs to show yet).
struct ResultRow: View {
    let name: String
    let address: String?
    var icon: String = "mappin.circle.fill"

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.headline)
                    .lineLimit(1)
                if let address, !address.isEmpty {
                    Text(address)
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
        case ..<3:  return .green
        case 3...8: return .yellow
        default:    return .orange
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            minutes(etaFromA)
            Text("|")
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
            minutes(etaFromB)
        }
        .font(.caption.weight(.semibold).monospacedDigit())
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(tint.opacity(0.18), in: Capsule())
        .foregroundStyle(tint)
    }

    private func minutes(_ eta: TimeInterval) -> some View {
        Text("\(Int((eta / 60).rounded())) min")
    }
}

/// A ranked place row: the place's name and address with its dual-ETA chip on
/// the trailing edge.
struct RankedResultRow: View {
    let spot: RankedSpot

    var body: some View {
        HStack(spacing: 12) {
            ResultRow(name: spot.item?.name ?? "Spot",
                      address: spot.item?.placemark.title)
            Spacer(minLength: 8)
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
