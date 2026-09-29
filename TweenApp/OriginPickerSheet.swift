import SwiftUI
import MapKit

/// "Where are you leaving from?" — the sheet that stands between tapping
/// I'm in and actually joining.
///
/// The whole point of saving Home is that joining a Tween from the sofa is one
/// tap and no GPS wait, so Home is the first row and the only one with a
/// filled treatment. Choosing it must NOT touch CoreLocation (spec §9): the
/// coordinate is already known, and asking for a fix anyway is what made
/// "I'm in" feel like a 20-second operation on a cold start.
///
/// Presentation-only. Every branch hands a `JoinChoice` back to
/// `OnboardingView`, which owns the join itself — the business logic for a
/// join lives in `OnboardingView+Actions`, not in a sheet (spec §29).
struct OriginPickerSheet: View {
    /// The user's saved Home, resolved by the presenter so this view never
    /// reads the store inside a body pass.
    let home: MyPlace?
    /// True while the join that this sheet started is still running, so the
    /// chosen row can show its own progress instead of a dead sheet.
    var busy: JoinChoice?

    let onChoose: (JoinChoice) -> Void

    /// What the user picked. `setUpHome` is not an origin — it's the detour
    /// to create one, after which the caller re-offers the picker.
    enum JoinChoice: Equatable {
        case home
        case currentLocation
        case somewhereElse
        case setUpHome
    }

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Tokens.Spacing.s3) {
                    Text("Pick where Tween should measure your travel time from. You can change it any time.")
                        .font(Tokens.Typography.footnote)
                        .foregroundStyle(Tokens.Palette.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.bottom, Tokens.Spacing.s1)

                    if let home {
                        originRow(
                            choice: .home,
                            symbol: MyPlaceKind.home.symbol,
                            title: "From \(home.label)",
                            subtitle: home.address ?? "Your saved address",
                            accessibilityLabel: "Leave from \(home.label)",
                            prominent: true)
                    } else {
                        originRow(
                            choice: .setUpHome,
                            symbol: MyPlaceKind.home.symbol,
                            title: "Set up Home",
                            subtitle: "Save it once — joining is one tap after that",
                            accessibilityLabel: "Set up Home",
                            prominent: true)
                    }

                    originRow(
                        choice: .currentLocation,
                        symbol: "location.fill",
                        title: "Current location",
                        subtitle: "Where you are right now",
                        accessibilityLabel: "Leave from your current location",
                        prominent: false)

                    originRow(
                        choice: .somewhereElse,
                        symbol: "magnifyingglass",
                        title: "Somewhere else",
                        subtitle: "An address you'll be leaving from",
                        accessibilityLabel: "Leave from another address",
                        prominent: false)
                }
                .padding(Tokens.Spacing.s4)
            }
            .navigationTitle("Where are you leaving from?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { dismiss() }
                        .disabled(busy != nil)
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }

    private func originRow(choice: JoinChoice,
                           symbol: String,
                           title: String,
                           subtitle: String,
                           accessibilityLabel: String,
                           prominent: Bool) -> some View {
        let isBusy = busy == choice
        return Button {
            onChoose(choice)
        } label: {
            HStack(spacing: Tokens.Spacing.s3) {
                // The glyph is never the only cue — the row's label carries
                // the meaning for VoiceOver and for anyone who reads icons
                // differently (spec §23).
                TweenRowIcon(systemImage: symbol,
                             color: prominent ? Tokens.Palette.brand : Tokens.Palette.textSecondary,
                             size: 40)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(isBusy ? "Joining…" : title)
                        .font(Tokens.Typography.headline)
                        .foregroundStyle(Tokens.Palette.textPrimary)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(Tokens.Typography.caption)
                        .foregroundStyle(Tokens.Palette.textSecondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if isBusy {
                    ProgressView()
                } else {
                    Image(systemName: "chevron.right")
                        .font(Tokens.Typography.caption)
                        .foregroundStyle(Tokens.Palette.textTertiary)
                        .accessibilityHidden(true)
                }
            }
            .padding(Tokens.Spacing.s3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(prominent ? Tokens.Palette.brandLight : Tokens.Palette.surfaceSecondary,
                        in: RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous))
        }
        .buttonStyle(.plain)
        // Disabled WHILE a join runs, so a second tap can't start a second one
        // (spec §21) — the sheet stays up until the caller dismisses it.
        .disabled(busy != nil)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(subtitle)
    }
}

#Preview("Home saved") {
    OriginPickerSheet(
        home: MyPlace(address: "1600 Amphitheatre Pkwy, Mountain View",
                      coordinate: .init(latitude: 37.42, longitude: -122.08)),
        onChoose: { _ in })
}

#Preview("No home") {
    OriginPickerSheet(home: nil, onChoose: { _ in })
}
