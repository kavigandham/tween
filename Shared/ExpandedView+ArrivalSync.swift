import SwiftUI

// Arrival Sync's surface inside the extension, on the screen where the group
// has already settled on a place — because that is the only screen where
// "I left" means anything, and it is the next thing anyone actually does.
//
// The whole feature is one row. Everything complicated (two route
// calculations, a broadcast, a scheduled reminder on somebody else's phone)
// happens behind it.
extension ExpandedView {

    /// The local user's Arrival Sync slice, if there is a sync running.
    var myArrivalEntry: ArrivalParticipantState? {
        guard let arrivalSync else { return nil }
        return arrivalSync.participant(localParticipantID ?? myName)
    }

    /// True when somebody ELSE started a sync this user has not answered — the
    /// receiving state, where the useful thing on screen is a leave time.
    var isAwaitingMyDeparture: Bool {
        guard let arrivalSync, let mine = myArrivalEntry else { return false }
        return arrivalSync.initiatedBy != (localParticipantID ?? myName)
            && mine.departureStatus != .departed
    }

    /// "Leave at 6:10 PM" / "Leave now" for the local user.
    var myDepartureLine: String? {
        guard let arrivalSync, let mine = myArrivalEntry,
              mine.departureStatus != .departed else { return nil }
        guard let travel = mine.estimatedTravelTime else { return nil }
        if ArrivalSyncTiming.shouldLeaveNow(targetArrival: arrivalSync.targetArrivalTime,
                                            travelTime: travel) {
            return "Leave now to arrive together"
        }
        guard let departure = mine.recommendedDepartureTime else { return nil }
        let minutes = ArrivalSyncTiming.leaveInMinutes(
            targetArrival: arrivalSync.targetArrivalTime, travelTime: travel)
        return "Leave in \(minutes) min · \(ArrivalSyncNotifier.timeFormatter.string(from: departure))"
    }

    /// Everyone else's leave time, for the person who just left: "Shiraaz in
    /// 10 min". Built from the same numbers the notification uses, so the two
    /// can never disagree.
    var othersDepartureLines: [String] {
        guard let arrivalSync else { return [] }
        let me = localParticipantID ?? myName
        return arrivalSync.pending
            .filter { $0.participantID != me }
            // One shared builder for every leave-time read-out (the banner,
            // the send status, this strip) so three surfaces cannot describe
            // the same minute three ways.
            .compactMap {
                ArrivalSyncNotifier.leaveLine(for: $0,
                                              targetArrival: arrivalSync.targetArrivalTime)
            }
    }

    /// The whole Arrival Sync block: the receiving state (somebody left, here
    /// is your leave time), the initiated state (you left, here is theirs), or
    /// the Pro upsell. Renders nothing when there is nothing to say — the
    /// screen already carries the place, directions, and the I Left row.
    @ViewBuilder
    var arrivalSyncBlock: some View {
        if let arrivalSync, isAwaitingMyDeparture, let line = myDepartureLine {
            arrivalSyncCard(
                title: "\(arrivalSync.initiatedByName) is on the way",
                detail: line,
                systemImage: "clock.fill",
                tint: myArrivalEntry?.departureStatus == .leaveNow
                    ? Tokens.Palette.warning : Tokens.Palette.brand)
        } else if arrivalSync != nil, !othersDepartureLines.isEmpty {
            arrivalSyncCard(
                title: "Arrival Sync",
                detail: othersDepartureLines.joined(separator: " · "),
                systemImage: "bell.fill",
                tint: Tokens.Palette.success)
        } else if !isProUnlocked, myEnRouteMark == nil {
            arrivalSyncUpsell
        }
    }

    /// Read-only status, deliberately not a button: the action on this screen
    /// is I Left, and a second tappable row competing with it is exactly the
    /// clutter this feature must not add.
    func arrivalSyncCard(title: String,
                         detail: String,
                         systemImage: String,
                         tint: Color) -> some View {
        HStack(spacing: Tokens.Spacing.s3) {
            Image(systemName: systemImage)
                .font(Tokens.Typography.title2)
                .foregroundStyle(tint)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Tokens.Typography.headline)
                    .foregroundStyle(Tokens.Palette.textPrimary)
                    .lineLimit(1)
                Text(detail)
                    .font(Tokens.Typography.caption)
                    .foregroundStyle(Tokens.Palette.textSecondary)
                    // Two lines, and scaling before truncating: a three-person
                    // group's leave times are genuinely long, and Dynamic Type
                    // at the largest sizes must not clip the one number the
                    // card exists to show.
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(Tokens.Spacing.s3)
        .frame(maxWidth: .infinity, minHeight: 60)
        .background(tint.opacity(0.14),
                    in: RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title). \(detail)")
    }

    /// The Pro upsell. One row, and it is the thing the spec asks to be
    /// tappable — a non-Pro user tapping Arrival Sync lands in the existing
    /// paywall, while the free "I Left" announcement above it keeps working
    /// untouched.
    var arrivalSyncUpsell: some View {
        Button(action: onUpgradeToPro) {
            HStack(spacing: Tokens.Spacing.s3) {
                Image(systemName: "bell.badge.fill")
                    .font(Tokens.Typography.title2)
                    .foregroundStyle(Tokens.Palette.brand)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: Tokens.Spacing.s1) {
                        Text("Arrival Sync")
                            .font(Tokens.Typography.headline)
                            .foregroundStyle(Tokens.Palette.textPrimary)
                        Text("PRO")
                            .font(Tokens.Typography.caption2Bold)
                            .foregroundStyle(Tokens.Palette.onBrand)
                            .padding(.horizontal, Tokens.Spacing.s1)
                            .padding(.vertical, 1)
                            .background(Tokens.Palette.brand, in: Capsule())
                    }
                    Text("Let Tween tell your friend when it's time to head out.")
                        .font(Tokens.Typography.caption)
                        .foregroundStyle(Tokens.Palette.textSecondary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(Tokens.Typography.captionBold)
                    .foregroundStyle(Tokens.Palette.textTertiary)
            }
            .padding(Tokens.Spacing.s3)
            .frame(maxWidth: .infinity, minHeight: 60)
            .background(Tokens.Palette.surfaceSecondary,
                        in: RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Arrival Sync, Tween Pro")
        .accessibilityHint("Tells everyone when to leave so you arrive together. Opens Tween Pro.")
    }
}
