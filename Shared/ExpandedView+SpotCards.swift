import SwiftUI
import UIKit
import MapKit
import CoreLocation

// Spot cards + the ranked spot list ExpandedView renders (split from
// ExpandedView.swift — structure plan R2; extension = same type, new file).
extension ExpandedView {
    // MARK: Spot cards

    /// Horizontally paging spot cards — every person's time on every card,
    /// replacing the vertical 40%-height list.
    var spotCardRail: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Tokens.Spacing.s3) {
                    ForEach(rankedSpots) { spot in
                        spotCard(spot).id(spot.id)
                    }
                }
                .padding(.horizontal, 1)
                .padding(.vertical, 2)
            }
            .onChange(of: selectedSpotID) { _, newValue in
                guard let newValue else { return }
                withAnimation(Tokens.Motion.snappy) {
                    proxy.scrollTo(newValue, anchor: .center)
                }
            }
            .sensoryFeedback(.selection, trigger: selectedSpotID)
        }
    }

    func spotCard(_ spot: RankedSpot) -> some View {
        let isSelected = selectedSpotID == spot.id
        let name = spot.item?.name ?? "Spot"
        return VStack(alignment: .leading, spacing: Tokens.Spacing.s2) {
            spotCardHeader(spot, name: name)
            spotCardPeople(spot)
            Spacer(minLength: 0)
            spotCardSpread(spot)
        }
        .padding(Tokens.Spacing.s3)
        .frame(width: spotCardWidth, height: spotCardHeight, alignment: .topLeading)
        .background(isSelected ? Tokens.Palette.brand.opacity(0.14) : Tokens.Palette.surface,
                    in: RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
                .strokeBorder(isSelected ? Tokens.Palette.brand : Color.clear, lineWidth: 1.5)
        }
        .animation(reduceMotion ? nil : Tokens.Motion.snappy, value: isSelected)
        .contentShape(Rectangle())
        .onTapGesture { select(spot) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(name), \(SpotETADisplay.compactLabel(for: spot, bestWorstETA: spotBestWorstETA))")
        .accessibilityHint("Selects this spot to send")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    func spotCardHeader(_ spot: RankedSpot, name: String) -> some View {
        let isBest = rankedSpots.first?.id == spot.id
        return HStack(spacing: Tokens.Spacing.s1) {
            Text(name)
                .font(Tokens.Typography.subheadline.weight(.semibold))
                .foregroundStyle(Tokens.Palette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Spacer(minLength: 0)
            if isBest {
                // Brand-colored "Best" — the recommendation, kept distinct from
                // the green/yellow/orange fairness tiers (device feedback: a
                // yellow star clashed with a green "Even" spot).
                Text("Best")
                    .font(Tokens.Typography.caption2Bold)
                    .foregroundStyle(Tokens.Palette.onBrand)
                    .padding(.horizontal, 6)
                    .frame(minHeight: 18)
                    .background(Tokens.Palette.brand, in: Capsule())
            }
        }
    }

    /// Shortest worst-case drive across the ranked spots — the reference the
    /// per-spot quality colour compares against.
    var spotBestWorstETA: TimeInterval? { rankedSpots.map(\.worstETA).min() }

    @ViewBuilder
    func spotCardPeople(_ spot: RankedSpot) -> some View {
        let extra = spot.etas.count - 4
        let tint = SpotETADisplay.qualityColor(for: spot, bestWorstETA: spotBestWorstETA)
        VStack(alignment: .leading, spacing: 5) {
            ForEach(spot.etas.prefix(4)) { eta in
                spotCardPersonRow(eta, tint: tint)
            }
            if extra > 0 {
                Text("+\(extra) more")
                    .font(Tokens.Typography.caption)
                    .foregroundStyle(Tokens.Palette.textTertiary)
            }
        }
    }

    func spotCardPersonRow(_ eta: ParticipantETA, tint: Color) -> some View {
        HStack(spacing: Tokens.Spacing.s1) {
            Text(SpotETADisplay.initials(for: eta.name))
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(Tokens.Palette.onBrand)
                .frame(width: 18, height: 18)
                .background(Tokens.Palette.brand, in: Circle())
            Text(eta.name)
                .font(Tokens.Typography.caption)
                .foregroundStyle(Tokens.Palette.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: Tokens.Spacing.s1)
            // Time coloured by the spot's fairness so a fair spot's rows read
            // green at a glance (device feedback: restore the color-coded times).
            // On a tinted capsule (like the host chip) so it stays readable in
            // both light and dark (post-push audit: bare yellow text was low
            // contrast on a light surface).
            Text(formatETA(eta.eta))
                .font(Tokens.Typography.captionBold.monospacedDigit())
                .foregroundStyle(tint)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 6)
                .frame(minHeight: 20)
                .background(tint.opacity(0.16), in: Capsule())
        }
    }

    func spotCardSpread(_ spot: RankedSpot) -> some View {
        let tint = SpotETADisplay.qualityColor(for: spot, bestWorstETA: spotBestWorstETA)
        return HStack(spacing: Tokens.Spacing.s1) {
            Circle()
                .fill(tint)
                .frame(width: 7, height: 7)
            Text(SpotETADisplay.qualityWord(for: spot, bestWorstETA: spotBestWorstETA))
                .font(Tokens.Typography.caption2Bold)
                .foregroundStyle(tint)
        }
    }

    /// The card rail's empty slot — ranking shimmer, waiting, or "no spots".
    /// Compact horizontal layout so it doesn't waste a tall block of space
    /// repeating the status (device feedback).
    var panelEmptyState: some View {
        HStack(spacing: Tokens.Spacing.s3) {
            Image(systemName: emptySpotListIcon)
                .font(.system(size: 22))
                .foregroundStyle(Tokens.Palette.accent)
                .frame(width: 34)
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
        .padding(Tokens.Spacing.s3)
        .background(Tokens.Palette.surface.opacity(0.6),
                    in: RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous))
        .accessibilityElement(children: .combine)
    }

}
