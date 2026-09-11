import SwiftUI

/// The Tween Pro pop-up: a compact, dismissible half-height sheet — never
/// an alert — that `NudgePolicy` raises after a random number of good
/// moments. It introduces Pro in three lines and hands off to the real
/// paywall; prices live on the paywall (StoreKit's), not here.
///
/// Every dismissal — Not now or a swipe — is recorded once by the host's
/// sheet `onDismiss` so the engine backs off; the sheet never blocks
/// anything and never shows during the tour or over another sheet (the
/// host gates that — see `OnboardingView.noteEngagement`).
struct ProNudgeSheet: View {
    /// Which moment raised it, so the pitch fits the moment.
    enum Reason {
        /// A random threshold of good moments (I'm in, a spot sent, agreed).
        case engagement
        /// Back from Maps, or a third return visit — people use Tween for a
        /// few minutes and head off; this catches them when they come back.
        case welcomeBack
    }

    var reason: Reason = .engagement

    @State private var showPaywall = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s4) {
            HStack(alignment: .firstTextBaseline) {
                Label("Tween Pro", systemImage: "sparkles")
                    .font(Tokens.Typography.title2.weight(.semibold))
                    .foregroundStyle(Tokens.Palette.textPrimary)
                Spacer(minLength: 0)
                Button("Not now") { dismiss() }
                .font(Tokens.Typography.subheadline.weight(.semibold))
                .foregroundStyle(Tokens.Palette.accent)
            }

            Text(reason == .welcomeBack
                 ? "Back from the drive? Pro plans the next one ahead — a time, a leave-by reminder, the whole crew in one tap."
                 : "You've been planning meetups. Pro makes the next ones one tap.")
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
