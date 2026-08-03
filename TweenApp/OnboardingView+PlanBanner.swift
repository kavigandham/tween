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

    /// Reopens the plan for its spot. Rebuilds the selection from the ranked
    /// list when that spot is still on screen so the sheet gets a live ETA;
    /// otherwise opens with what we know, which is enough to edit the time.
    func reopenPlan(spotName: String) {
        if let ranked = rankedSpots.first(where: { $0.item?.name == spotName }),
           let item = ranked.item {
            spotSubSheet = nil
            presentSpot(SpotSelection(item: item, ranked: ranked))
            spotSubSheet = .plan(SpotSelection(item: item, ranked: ranked))
            return
        }
        // Not in the current results — still let them edit or cancel it.
        let placemark = MKPlacemark(coordinate: MeetupPlanStore.current.coordinate
                                    ?? Self.defaultCenter)
        let item = MKMapItem(placemark: placemark)
        item.name = spotName
        spotSubSheet = .plan(SpotSelection(item: item, ranked: nil))
    }

    func cancelPlan() {
        MeetupPlanStore.clear()
        LeaveByReminder.cancel()
        rerankAfterPlanChange()
        showToast("Plan cancelled")
    }
}
