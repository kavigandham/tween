import SwiftUI
import UIKit
import MapKit
import CoreLocation

// The ranked-spot list ExpandedView renders (split from ExpandedView.swift —
// structure plan R2; extension = same type, new file).
//
// Shape follows Apple Maps' own results list, studied side by side on device
// (2026-08-02): ONE grouped container, two-line rows, a circular leading icon,
// and hairline separators inset to the text's leading edge. The previous
// horizontal rail of bordered mini-cards — each stacking four colour-filled ETA
// rows — was the single densest thing in the extension and read as clunky next
// to Maps' calm list. Same information, Apple's structure:
//
//   ◉  Blue Bottle Coffee                    ✓
//      Fair · You 21 · Kavi 23
//      ───────────────────────────────
//   ◉  Sightglass Coffee
//      Longer · You 15 · Kavi 31
//
extension ExpandedView {
    // MARK: Spot list

    /// Ranked spots as one grouped list. Scrolls internally when the group is
    /// long; the container itself never grows past `spotListMaxHeight` so the
    /// map keeps its share of the extension's fixed height.
    var spotCardRail: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    ForEach(Array(rankedSpots.enumerated()), id: \.element.id) { index, spot in
                        spotRow(spot, isFirst: index == 0)
                            .id(spot.id)
                        if index < rankedSpots.count - 1 {
                            // Inset separator — starts at the text's leading
                            // edge, past the icon, exactly as Maps does. An
                            // explicit hairline, not `Divider()`: the system
                            // divider is invisible against this fill.
                            Rectangle()
                                .fill(Tokens.Palette.textPrimary.opacity(0.12))
                                .frame(height: 1 / UIScreen.main.scale)
                                .padding(.leading, spotRowIconSize + Tokens.Spacing.s3 * 2)
                        }
                    }
                }
            }
            .frame(maxHeight: spotListMaxHeight)
            .background(Tokens.Palette.elevated,
                        in: RoundedRectangle(cornerRadius: Tokens.Radius.group, style: .continuous))
            .onChange(of: selectedSpotID) { _, newValue in
                guard let newValue else { return }
                withAnimation(Tokens.Motion.snappy) {
                    proxy.scrollTo(newValue, anchor: .center)
                }
            }
            .sensoryFeedback(.selection, trigger: selectedSpotID)
        }
    }

    /// Three rows fit without scrolling — past that the list scrolls rather
    /// than eating the map.
    var spotListMaxHeight: CGFloat { spotRowHeight * 3 + 2 }
    var spotRowHeight: CGFloat { 62 }
    var spotRowIconSize: CGFloat { 34 }

    func spotRow(_ spot: RankedSpot, isFirst: Bool) -> some View {
        let isSelected = selectedSpotID == spot.id
        let name = spot.item?.name ?? "Spot"
        let tint = SpotETADisplay.qualityColor(for: spot, bestWorstETA: spotBestWorstETA)
        return Button {
            select(spot)
        } label: {
            HStack(spacing: Tokens.Spacing.s3) {
                // Leading mark: the fairness colour carried on one small
                // circle, a star on the recommended spot. One spot of colour
                // per row — Maps' discipline — instead of a colour-filled
                // capsule behind every number.
                ZStack {
                    Circle().fill(tint.opacity(0.22))
                    Image(systemName: isFirst ? "star.fill" : "mappin")
                        .font(.system(size: spotRowIconSize * 0.42, weight: .semibold))
                        .foregroundStyle(tint)
                }
                .frame(width: spotRowIconSize, height: spotRowIconSize)

                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(Tokens.Typography.subheadline.weight(.semibold))
                        .foregroundStyle(Tokens.Palette.textPrimary)
                        .lineLimit(1)
                    // One secondary line, Maps-style: verdict, then each
                    // person's drive separated by middots. Everyone's time is
                    // still here — it just stops shouting.
                    Text(spotRowSubtitle(spot))
                        .font(Tokens.Typography.caption)
                        .foregroundStyle(Tokens.Palette.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }

                Spacer(minLength: Tokens.Spacing.s2)

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(Tokens.Typography.headline)
                        .foregroundStyle(Tokens.Palette.accent)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.horizontal, Tokens.Spacing.s3)
            .frame(height: spotRowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.spotRow)
        .background(isSelected ? Tokens.Palette.brand.opacity(0.16) : Color.clear)
        .animation(reduceMotion ? nil : Tokens.Motion.snappy, value: isSelected)
        .accessibilityLabel("\(name), \(SpotETADisplay.compactLabel(for: spot, bestWorstETA: spotBestWorstETA))")
        .accessibilityHint("Selects this spot to send")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    /// "Fair · You 21 · Kavi 23" — the verdict plus as many people as fit.
    /// A spot past the user's max-drive-time preference says so first, so a
    /// demoted row explains its own position instead of looking mis-sorted.
    func spotRowSubtitle(_ spot: RankedSpot) -> String {
        // Say it plainly when a planned mode couldn't be answered. Apple only
        // returns transit times where it has coverage; these numbers are the
        // real driving route instead, and presenting them as transit would be
        // a lie the user can't detect (2026-08-04).
        if spot.etas.contains(where: \.modeUnavailable) {
            let people = spot.etas.prefix(3).map { eta in
                "\(SpotETADisplay.shortName(for: eta.name)) \(Int((eta.eta / 60).rounded()))"
            }
            return (["No transit here — driving"] + people).joined(separator: " · ")
        }
        let verdict = spot.exceedsDriveLimit
            ? "Over your limit"
            : SpotETADisplay.qualityWord(for: spot, bestWorstETA: spotBestWorstETA)
        let people = spot.etas.prefix(3).map { eta in
            "\(SpotETADisplay.shortName(for: eta.name)) \(Int((eta.eta / 60).rounded()))"
        }
        let extra = spot.etas.count - 3
        var parts = [verdict] + people
        if extra > 0 { parts.append("+\(extra)") }
        return parts.joined(separator: " · ")
    }

    /// Shortest worst-case drive across the ranked spots — the reference the
    /// per-spot quality colour compares against.
    var spotBestWorstETA: TimeInterval? { rankedSpots.map(\.worstETA).min() }

    /// The list's empty slot — ranking shimmer, waiting, or "no spots".
    /// Matches the list container so the panel's shape doesn't jump when
    /// results arrive.
    var panelEmptyState: some View {
        HStack(spacing: Tokens.Spacing.s3) {
            Image(systemName: emptySpotListIcon)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Tokens.Palette.accent)
                .frame(width: spotRowIconSize, height: spotRowIconSize)
                .background(Tokens.Palette.accent.opacity(0.16), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(emptySpotListTitle)
                    .font(Tokens.Typography.subheadline.weight(.semibold))
                    .foregroundStyle(Tokens.Palette.textPrimary)
                Text(emptySpotListSubtitle)
                    .font(Tokens.Typography.caption)
                    .foregroundStyle(Tokens.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Tokens.Spacing.s3)
        .frame(minHeight: spotRowHeight)
        .background(Tokens.Palette.elevated,
                    in: RoundedRectangle(cornerRadius: Tokens.Radius.group, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// Row press feedback: the whole row dims on touch-DOWN, the way a Maps list
/// row does — instant, no scale, no ripple.
struct SpotRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed
                        ? Tokens.Palette.textPrimary.opacity(0.08)
                        : Color.clear)
    }
}

extension ButtonStyle where Self == SpotRowButtonStyle {
    static var spotRow: SpotRowButtonStyle { SpotRowButtonStyle() }
}
