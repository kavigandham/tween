import SwiftUI
import MapKit

// The saved plan, made visible.
//
// Saving a plan used to leave NO trace anywhere on screen: the sheet dismissed,
// ranking shifted subtly, and the only evidence was a "Planned" label on the one
// spot card you'd have to reopen to find. The reasonable reaction was "I saved
// the plan — where did it go?" (device report 2026-08-02).
//
// A plan is state the user created and expects to see, edit, and cancel. This is
// its home.
extension OnboardingView {
    @ViewBuilder
    var plannedMeetupBanner: some View {
        let plan = MeetupPlanStore.current
        if let arrival = plan.arrivalDate, let spot = plan.spotName {
            Button {
                reopenPlan(spotName: spot)
            } label: {
                HStack(spacing: Tokens.Spacing.s3) {
                    TweenRowIcon(systemImage: "calendar.badge.clock",
                                 color: Tokens.Palette.brand, size: 36)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(spot)
                            .font(Tokens.Typography.subheadline.weight(.semibold))
                            .foregroundStyle(Tokens.Palette.textPrimary)
                            .lineLimit(1)
                        Text(planSubtitle(arrival: arrival, plan: plan))
                            .font(Tokens.Typography.caption)
                            .foregroundStyle(Tokens.Palette.textSecondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 0)

                    Image(systemName: "chevron.right")
                        .font(Tokens.Typography.captionBold)
                        .foregroundStyle(Tokens.Palette.textTertiary)
                }
                .padding(Tokens.Spacing.s3)
                .background(Tokens.Palette.elevated,
                            in: RoundedRectangle(cornerRadius: Tokens.Radius.group, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, Tokens.Spacing.s4)
            .accessibilityLabel("Planned meetup at \(spot)")
            .accessibilityHint("Opens the plan to change the time, travel modes, or cancel it")
            .contextMenu {
                Button(role: .destructive) {
                    cancelPlan()
                } label: {
                    Label("Cancel plan", systemImage: "trash")
                }
            }
        }
    }

    /// "Today at 7:00 PM · You walking" — the time, plus any non-driving mode so
    /// a plan that changes the ranking explains itself without being opened.
    func planSubtitle(arrival: Date, plan: MeetupPlan) -> String {
        var parts = [arrival.formatted(date: .abbreviated, time: .shortened)]
        let myMode = plan.mode(for: TweenIdentity.stableID)
        if myMode != .driving { parts.append("You \(myMode.title.lowercased())") }
        let others = plan.modes.filter { $0.key != TweenIdentity.stableID }.count
        if others > 0 { parts.append("\(others) not driving") }
        return parts.joined(separator: " · ")
    }

    /// Reopens the plan for its spot.
    ///
    /// Presents through the banner's OWN sheet state, not `spotSubSheet`. That
    /// binding's `.sheet(item:)` is attached inside `spotDetailSheet`, which is
    /// only in the hierarchy while a spot card is open — and the banner lives
    /// in the bottom sheet, where `activeSheet` is nil. Setting `spotSubSheet`
    /// from here presented NOTHING and left it armed: the same dead-affordance
    /// bug already fixed once for the paywall, reintroduced (audit 2026-08-03).
    ///
    /// Also does NOT fabricate a coordinate. The old fallback used
    /// `Self.defaultCenter` — the geographic centre of Kansas that the search
    /// code elsewhere treats as "no anchor at all" — which Save would then
    /// persist as the plan's location and the calendar event's place.
    /// `PlanMeetupSheet` takes an optional coordinate, so nil is honest and
    /// safe; only the reminder needs one, and it degrades on its own.
    func reopenPlan(spotName: String) {
        let ranked = rankedSpots.first { $0.item?.name == spotName }
        planSheet = PlanSheetItem(
            spotName: spotName,
            coordinate: ranked?.item?.placemark.coordinate ?? MeetupPlanStore.current.coordinate,
            ranked: ranked)
    }

    func cancelPlan() {
        MeetupPlanStore.clear()
        LeaveByReminder.cancel()
        rerankAfterPlanChange()
        showToast("Plan cancelled")
    }
}

/// What the banner presents. Its own type (and its own `.sheet(item:)` on the
/// bottom-sheet content) because the banner is reachable when NO spot card is
/// open, so it cannot share `spotSubSheet`'s presenter.
struct PlanSheetItem: Identifiable {
    let id = UUID()
    let spotName: String
    let coordinate: CLLocationCoordinate2D?
    let ranked: RankedSpot?
}

extension OnboardingView {
    /// The plan sheet presented FROM the bottom sheet — the permanently
    /// presented surface the banner lives on, so this presenter always exists.
    @ViewBuilder
    func planSheetContent(_ item: PlanSheetItem) -> some View {
        let myETA: TimeInterval? = item.ranked?.etas
            .first { $0.id == TweenIdentity.stableID }?.eta
        let roster: [Participant] = searchRankingParticipants ?? currentParticipants
        PlanMeetupSheet(
            spotName: item.spotName,
            coordinate: item.coordinate,
            myTravelTime: myETA,
            participants: roster,
            localParticipantID: TweenIdentity.stableID,
            onSaved: { rerankAfterPlanChange() })
    }
}
