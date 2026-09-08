import SwiftUI

/// The Tween Pro pop-up: a compact, dismissible half-height sheet — never
/// an alert — that `NudgePolicy` raises after a random number of good
/// moments. It introduces Pro in three lines and hands off to the real
/// paywall; prices live on the paywall (StoreKit's), not here.
///
/// "Not now" is recorded so the engine backs off; the sheet never blocks
/// anything and never shows during the tour or over another sheet (the
/// host gates that — see `OnboardingView.noteEngagement`).
struct ProNudgeSheet: View {
    /// Called on "Not now" (and on a swipe-down, via the host's onDismiss).
    var onNotNow: () -> Void

    @State private var showPaywall = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s4) {
            HStack(alignment: .firstTextBaseline) {
                Label("Tween Pro", systemImage: "sparkles")
                    .font(Tokens.Typography.title2.weight(.semibold))
                    .foregroundStyle(Tokens.Palette.textPrimary)
                Spacer(minLength: 0)
                Button("Not now") {
                    onNotNow()
                    dismiss()
                }
                .font(Tokens.Typography.subheadline.weight(.semibold))
                .foregroundStyle(Tokens.Palette.accent)
            }

            Text("You've been planning meetups. Pro makes the next ones one tap.")
                .font(Tokens.Typography.subheadline)
                .foregroundStyle(Tokens.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: Tokens.Spacing.s3) {
                feature("person.3.fill", "Groups",
                        "Save the crew. One tap finds fair spots between everyone's home bases.")
                feature("house.fill", "Saved places",
                        "Home, work, anywhere — for friends who aren't on Tween yet.")
                feature("calendar", "Plan ahead",
                        "Set a time, get a leave-by reminder, and a calendar invite.")
            }

            Button {
                showPaywall = true
            } label: {
                Text("See Tween Pro")
                    .font(Tokens.Typography.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: Tokens.Layout.primaryControlHeight)
            }
            .buttonStyle(.tweenPrimary())
            .accessibilityHint("Opens the Tween Pro options")
        }
        .padding(Tokens.Spacing.s5)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .sheet(isPresented: $showPaywall) {
            PaywallSheet()
        }
        // Bought from the paywall: nothing left to nudge about.
        .onChange(of: showPaywall) { _, presented in
            if !presented, ProEntitlement.isUnlocked { dismiss() }
        }
    }

    private func feature(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: Tokens.Spacing.s3) {
            TweenRowIcon(systemImage: symbol, color: Tokens.Palette.brand)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Tokens.Typography.headline)
                    .foregroundStyle(Tokens.Palette.textPrimary)
                Text(detail)
                    .font(Tokens.Typography.footnote)
                    .foregroundStyle(Tokens.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
