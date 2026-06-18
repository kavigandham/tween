import SwiftUI

/// A single tutorial page: an SF Symbol icon, a headline, and a short body.
private struct TutorialCard: Identifiable {
    let id = UUID()
    let icon: String
    let headline: String
    let body: String
}

/// First-run walkthrough shown over the main map. Seven swipeable cards explain
/// the meetup flow end to end. Dismissing flips `OnboardingFlags.hasSeenOnboarding`
/// so it never auto-shows again; the main screen's info button can re-present it.
struct OnboardingTutorialView: View {
    var onDone: () -> Void

    private static let cards: [TutorialCard] = [
        TutorialCard(icon: "hand.wave.fill",
                     headline: "Welcome to Tween",
                     body: "The fairest way to decide where two friends should meet."),
        TutorialCard(icon: "location.fill",
                     headline: "Tap “I'm in”",
                     body: "Share where you are with one tap. Your location stays on your device."),
        TutorialCard(icon: "person.2.fill",
                     headline: "Your friend taps “I'm in”",
                     body: "They share their spot from the same iMessage bubble."),
        TutorialCard(icon: "scalemass.fill",
                     headline: "Fair spots appear",
                     body: "Tween ranks places by drive time so neither of you gets the long haul."),
        TutorialCard(icon: "mappin.and.ellipse",
                     headline: "Pick a spot",
                     body: "Tap any result to see details, the map, and the drive times."),
        TutorialCard(icon: "bubble.left.and.bubble.right.fill",
                     headline: "It lands in iMessage",
                     body: "Hit “Send to chat” and the spot drops straight into your conversation."),
        TutorialCard(icon: "checkmark.seal.fill",
                     headline: "That's it",
                     body: "No accounts, no servers — just you, a friend, and a fair place to meet.")
    ]

    @State private var selection = 0

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $selection) {
                ForEach(Array(Self.cards.enumerated()), id: \.element.id) { index, card in
                    cardView(card).tag(index)
                }
            }
            .tabViewStyle(.page)
            .indexViewStyle(.page(backgroundDisplayMode: .always))

            Button(action: onDone) {
                Text(selection == Self.cards.count - 1 ? "Get Started" : "Skip")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(24)
        }
    }

    private func cardView(_ card: TutorialCard) -> some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: card.icon)
                .font(.system(size: 72))
                .foregroundStyle(.tint)
                .frame(height: 120)
            Text(card.headline)
                .font(.title.weight(.bold))
                .multilineTextAlignment(.center)
            Text(card.body)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .padding(.horizontal, 32)
    }
}

#Preview {
    OnboardingTutorialView(onDone: {})
}
