import SwiftUI

/// Shared rendering of a spot's per-participant drive times.
///
/// Audit F1: the host app capped drive times at two people — four render sites
/// read the legacy `RankedSpot.etaFromA/etaFromB` accessors and drew an
/// A/B pill — while the Messages extension already showed all N. The ranking
/// pipeline has always produced N-person ETAs with names (`FairnessRanker`);
/// the gap was 100% render-side. This namespace + its views are the single
/// source of truth both processes use, so host and extension render identical
/// times. Pure display — no ranking, no side effects.
enum SpotETADisplay {
    /// One `(name, time)` pair per participant — always a real name, so people
    /// see their OWN drive time, not a "Best/Typical/Long" summary (device
    /// feedback). Only a genuinely large group (7+) collapses to keep the strip
    /// readable. Empty `etas` (the legacy 2-person `RankedSpot` init used by
    /// tests/previews) falls back to A / B.
    static func chipItems(for spot: RankedSpot) -> [(String, String)] {
        if spot.etas.isEmpty {
            return [("A", formatETA(spot.etaFromA)), ("B", formatETA(spot.etaFromB))]
        }
        if spot.etas.count <= 6 {
            return spot.etas.map { ($0.name, formatETA($0.eta)) }
        }
        // Very large groups: show the fastest five by name, then a count.
        let sorted = spot.etas.sorted { $0.eta < $1.eta }
        var items = sorted.prefix(5).map { ($0.name, formatETA($0.eta)) }
        items.append(("+\(spot.etas.count - 5) more", ""))
        return items
    }

    /// One-line summary for tight trailing slots (result-list rows) and map-pin
    /// labels. Names + times for ≤2, a "N people · X spread" summary at 3+ so
    /// the pill stays compact.
    static func compactLabel(for spot: RankedSpot) -> String {
        let etas = spot.etas
        if etas.isEmpty {
            return "A \(formatETA(spot.etaFromA)) · B \(formatETA(spot.etaFromB))"
        }
        if etas.count <= 2 {
            return etas.map { "\($0.name) \(formatETA($0.eta))" }.joined(separator: " · ")
        }
        return "\(etas.count) people · \(fairnessWord(for: spot))"
    }

    /// Plain-language fairness for the place sheet — no "X min spread" jargon
    /// (device feedback: "what even is an 8 minute spread"). The per-person
    /// times already show the detail; this just says how even the trip is.
    static func fairnessCaption(for spot: RankedSpot) -> String {
        switch spot.fairnessSpread {
        case ..<300: return "Everyone drives about the same"
        case ..<900: return "A fairly even trip for everyone"
        default:     return "A longer drive for some than others"
        }
    }

    /// One-word fairness tag for a compact chip.
    static func fairnessWord(for spot: RankedSpot) -> String {
        switch spot.fairnessSpread {
        case ..<300: return "Even"
        case ..<900: return "Fair"
        default:     return "Uneven"
        }
    }

    static func fairnessColor(for spot: RankedSpot) -> Color {
        switch spot.fairnessSpread {
        case ..<300: return Tokens.Palette.fairnessGood
        case ..<900: return Tokens.Palette.fairnessOkay
        default:     return Tokens.Palette.fairnessPoor
        }
    }

    static func initials(for name: String) -> String {
        let words = name.split(separator: " ")
        let letters = words.prefix(2).compactMap { $0.first }
        let result = String(letters).uppercased()
        return result.isEmpty ? "?" : result
    }

    // MARK: Drive-balance geometry (avatars on a spread track)

    /// Caps the avatars drawn on the balance track at six; anything larger
    /// keeps the five fastest plus the single slowest so the spread stays
    /// legible.
    static func visibleETAs(for spot: RankedSpot) -> [ParticipantETA] {
        guard spot.etas.count > 6 else { return spot.etas }
        let sorted = spot.etas.sorted { $0.eta < $1.eta }
        var visible = Array(sorted.prefix(5))
        if let longest = sorted.last, !visible.contains(where: { $0.id == longest.id }) {
            visible.append(longest)
        }
        return visible
    }

    static func position(for eta: ParticipantETA, in spot: RankedSpot, trackWidth: CGFloat) -> CGFloat {
        let range = max(spot.worstETA - spot.bestETA, 60)
        let fraction = CGFloat((eta.eta - spot.bestETA) / range)
        return min(max(fraction * trackWidth, 0), trackWidth)
    }

    static func spreadStart(for spot: RankedSpot, trackWidth: CGFloat) -> CGFloat {
        guard let first = spot.etas.min(by: { $0.eta < $1.eta }) else { return 0 }
        return position(for: first, in: spot, trackWidth: trackWidth) + 11
    }

    static func spreadWidth(for spot: RankedSpot, trackWidth: CGFloat) -> CGFloat {
        guard let first = spot.etas.min(by: { $0.eta < $1.eta }),
              let last = spot.etas.max(by: { $0.eta < $1.eta }) else { return 0 }
        return max(position(for: last, in: spot, trackWidth: trackWidth)
                   - position(for: first, in: spot, trackWidth: trackWidth), 8)
    }
}

// MARK: - Views

/// Horizontal strip of per-participant time chips. Used by the host result
/// card + place sheet and the extension's spot rows so both render identically.
struct SpotETAStrip: View {
    let spot: RankedSpot

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Tokens.Spacing.s1) {
                let chips = SpotETADisplay.chipItems(for: spot)
                ForEach(Array(chips.enumerated()), id: \.offset) { _, chip in
                    SpotETAChip(label: chip.0, value: chip.1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Drive times")
        .accessibilityValue(SpotETADisplay.compactLabel(for: spot))
    }
}

/// One name/label + time capsule.
struct SpotETAChip: View {
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 3) {
            if !label.isEmpty {
                Text(label).foregroundStyle(Tokens.Palette.textSecondary)
            }
            Text(value).foregroundStyle(Tokens.Palette.textPrimary)
        }
        .font(Tokens.Typography.captionBold)
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, Tokens.Spacing.s2)
        .frame(minHeight: 24)
        .background(Tokens.Palette.surface, in: Capsule())
    }
}

/// Compact fairness-tinted pill for tight trailing slots (result-list rows).
/// Shows both names/times for a pair, a "N people · spread" summary at 3+.
struct SpotETASummaryPill: View {
    let spot: RankedSpot

    var body: some View {
        Text(SpotETADisplay.compactLabel(for: spot))
            .font(Tokens.Typography.captionBold.monospacedDigit())
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, Tokens.Spacing.s3)
            .padding(.vertical, Tokens.Spacing.s2)
            .background(SpotETADisplay.fairnessColor(for: spot).opacity(0.18), in: Capsule())
            .foregroundStyle(SpotETADisplay.fairnessColor(for: spot))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Drive times")
            .accessibilityValue(SpotETADisplay.compactLabel(for: spot))
    }
}

/// The drive-balance track: each participant's avatar placed by their drive
/// time along a spread bar. Rendered for 3+ participants where the flat chip
/// strip alone doesn't convey how lopsided the trip is.
struct SpotDriveBalance: View {
    let spot: RankedSpot

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s2) {
            HStack(alignment: .firstTextBaseline) {
                Text("Who drives how long")
                    .font(Tokens.Typography.captionBold)
                    .foregroundStyle(Tokens.Palette.textSecondary)
                Spacer(minLength: 0)
                Text(SpotETADisplay.fairnessWord(for: spot))
                    .font(Tokens.Typography.caption2Bold)
                    .foregroundStyle(SpotETADisplay.fairnessColor(for: spot))
            }

            GeometryReader { proxy in
                let visible = SpotETADisplay.visibleETAs(for: spot)
                let trackWidth = max(proxy.size.width - 22, 1)
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Tokens.Palette.neutralAction)
                        .frame(height: 8)
                        .offset(y: 11)

                    Capsule()
                        .fill(SpotETADisplay.fairnessColor(for: spot).opacity(0.22))
                        .frame(width: SpotETADisplay.spreadWidth(for: spot, trackWidth: trackWidth), height: 8)
                        .offset(x: SpotETADisplay.spreadStart(for: spot, trackWidth: trackWidth), y: 11)

                    ForEach(visible) { eta in
                        let xOffset = SpotETADisplay.position(for: eta, in: spot, trackWidth: trackWidth)
                        Text(SpotETADisplay.initials(for: eta.name))
                            .font(Tokens.Typography.caption2Bold)
                            .foregroundStyle(.white)
                            .frame(width: 22, height: 22)
                            .background(Tokens.Palette.brand, in: Circle())
                            .overlay(Circle().strokeBorder(Tokens.Palette.surface, lineWidth: 2))
                            .offset(x: xOffset)
                            .accessibilityLabel("\(eta.name), \(formatETA(eta.eta))")
                    }

                    if spot.etas.count > visible.count {
                        Text("+\(spot.etas.count - visible.count)")
                            .font(Tokens.Typography.caption2Bold)
                            .foregroundStyle(Tokens.Palette.textSecondary)
                            .frame(width: 28, height: 22)
                            .background(Tokens.Palette.surface, in: Capsule())
                            .overlay(Capsule().strokeBorder(Tokens.Palette.surfaceSecondary, lineWidth: 1))
                            .offset(x: max(trackWidth - 28, 0))
                    }
                }
            }
            .frame(height: 32)
        }
        .padding(Tokens.Spacing.s2)
        .background(Tokens.Palette.surface.opacity(0.72),
                    in: RoundedRectangle(cornerRadius: Tokens.Radius.chip, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}
