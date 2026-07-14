import SwiftUI
import UIKit
import MapKit
import CoreLocation

// Meetup-set hero + the scrolling spot list (split from ExpandedView.swift).
extension ExpandedView {
    // MARK: Spot list

    /// MEETUP SET — the terminal hero shown when the bubble's messageType is
    /// `.agree` and every non-proposer participant has agreed. Agreement is
    /// terminal for negotiation, but the user still needs to leave the meetup.
    func meetupSetView(state: TweenState) -> some View {
        // Map gets its own region above the panel (device feedback).
        mapSection
            .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: Tokens.Spacing.s4) {
                Capsule()
                    .fill(Tokens.Palette.textTertiary.opacity(0.35))
                    .frame(width: 42, height: 5)
                    .accessibilityHidden(true)

                HStack(alignment: .center, spacing: Tokens.Spacing.s3) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(Tokens.Typography.title)
                        .foregroundStyle(Tokens.Palette.success)
                        .symbolRenderingMode(.hierarchical)

                    VStack(alignment: .leading, spacing: Tokens.Spacing.s1) {
                        Text("It's a plan")
                            .font(Tokens.Typography.headline)
                            .foregroundStyle(Tokens.Palette.textSecondary)
                        Text(state.text)
                            .font(Tokens.Typography.title.weight(.bold))
                            .foregroundStyle(Tokens.Palette.textPrimary)
                            .lineLimit(2)
                            .minimumScaleFactor(0.72)
                    }

                    Spacer(minLength: 0)
                }

                // One button, the user's maps app (Settings → Apple/Google) —
                // the old Apple/Google pair made every user read two options
                // to find theirs.
                directionRow(
                    title: "Open in Maps",
                    subtitle: "Driving directions to \(state.text)",
                    systemImage: "arrow.triangle.turn.up.right.diamond.fill",
                    foreground: .white,
                    background: Tokens.Palette.brand
                ) {
                    sendTick += 1
                    onOpenInMaps(state)
                }

                HStack(spacing: Tokens.Spacing.s2) {
                    if isUserIn {
                        Button {
                            sendTick += 1
                            onImOut()
                        } label: {
                            Label("I'm out", systemImage: "location.slash")
                                .lineLimit(1)
                                .minimumScaleFactor(0.78)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.tweenPrimary(.destructive))
                        .disabled(isSending)
                        .accessibilityHint("Stops sharing you as active for this meetup")
                    } else {
                        Button(action: onImIn) {
                            Label("I'm in", systemImage: "location.fill")
                                .lineLimit(1)
                                .minimumScaleFactor(0.78)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.tweenPrimary())
                        .disabled(isSending)
                        .accessibilityHint("Shares where you are for this meetup")
                    }

                    Button(action: onOpenFullApp) {
                        Label("Search", systemImage: "magnifyingglass")
                            .lineLimit(1)
                            .minimumScaleFactor(0.78)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.tweenPrimary(.subtle))
                    .accessibilityHint("Opens the full Tween app to search for places")
                }
            }
            .padding(Tokens.Spacing.s4)
            .background(.regularMaterial, in: UnevenRoundedRectangle(
                topLeadingRadius: Tokens.Radius.sheet,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: Tokens.Radius.sheet,
                style: .continuous
            ))
            .overlay(alignment: .top) {
                UnevenRoundedRectangle(
                    topLeadingRadius: Tokens.Radius.sheet,
                    bottomLeadingRadius: 0,
                    bottomTrailingRadius: 0,
                    topTrailingRadius: Tokens.Radius.sheet,
                    style: .continuous
                )
                .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
            }
            .tweenElevation(.sheet)
            .sensoryFeedback(.success, trigger: isMeetupSet)
        }
        .background(Color(.systemBackground))
    }

    func directionRow(
        title: String,
        subtitle: String,
        systemImage: String,
        foreground: Color,
        background: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: Tokens.Spacing.s3) {
                Image(systemName: systemImage)
                    .font(Tokens.Typography.headline)
                    .foregroundStyle(foreground)
                    .frame(width: 40, height: 40)
                    .background(foreground.opacity(0.16), in: RoundedRectangle(cornerRadius: Tokens.Radius.chip, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(Tokens.Typography.headline)
                        .foregroundStyle(foreground)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(Tokens.Typography.caption)
                        .foregroundStyle(foreground.opacity(0.78))
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(Tokens.Typography.captionBold)
                    .foregroundStyle(foreground.opacity(0.72))
            }
            .padding(Tokens.Spacing.s3)
            .frame(maxWidth: .infinity, minHeight: 60)
            .background(background, in: RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    var emptySpotListIcon: String {
        if isWaitingForCoordinates { return "location.circle" }
        if !hasEnoughPeopleForSpots { return "person.2" }
        return isRanking ? "mappin.and.ellipse" : "magnifyingglass"
    }

    var emptySpotListTitle: String {
        if isWaitingForCoordinates { return "Getting locations" }
        if !hasEnoughPeopleForSpots { return "Waiting for someone else" }
        return isRanking ? "Finding fair spots..." : "No fair spots found"
    }

    var emptySpotListSubtitle: String {
        if isWaitingForCoordinates {
            return "Both people are in, but Tween needs both shared locations before ranking."
        }
        if !hasEnoughPeopleForSpots {
            return "Fair spots appear once at least two people are in."
        }
        return isRanking
            ? "Hang tight while Tween ranks nearby places."
            : "Try Browse spots to pick a place manually."
    }

    /// Single point of truth for selection. Updates `selectedSpotID`, which
    /// scrolls the list, re-styles the pin, and re-focuses the snapshot (the
    /// snapshot's focusCoordinate follows the selected spot).
    func select(_ spot: RankedSpot, animateMap: Bool = false) {
        selectedSpotID = spot.id
    }

}
