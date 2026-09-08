import SwiftUI

/// The tour's "what happens in iMessage" illustration: a thread with the
/// Tween bubble you send and the friend's Agree beneath it. Vectors, not a
/// screenshot — screenshots go stale with every UI change and cost asset
/// weight; this stays current with the tokens.
struct ChatIllustration: View {
    var spotName = "Coffeebar"
    var friendName = "Sam"

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s2) {
            // Thread header, the way Messages shows the person.
            HStack(spacing: Tokens.Spacing.s2) {
                Text(String(friendName.prefix(1)))
                    .font(Tokens.Typography.captionBold)
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(Tokens.Palette.pinFriend, in: Circle())
                Text(friendName)
                    .font(Tokens.Typography.captionBold)
                    .foregroundStyle(Tokens.Palette.textSecondary)
                Spacer(minLength: 0)
            }

            // Your Tween bubble: the spot, a strip of map, everyone's time.
            HStack {
                Spacer(minLength: 40)
                VStack(alignment: .leading, spacing: Tokens.Spacing.s2) {
                    miniMap
                        .frame(height: 54)
                    Text("Let's meet at \(spotName)")
                        .font(Tokens.Typography.captionBold)
                        .foregroundStyle(.white)
                    Text("You 12 min · \(friendName) 14 min")
                        .font(Tokens.Typography.caption)
                        .foregroundStyle(.white.opacity(0.85))
                }
                .padding(Tokens.Spacing.s3)
                .background(Tokens.Palette.pinSelf,
                            in: RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous))
            }

            // Their reply, straight from the bubble's Agree button.
            HStack {
                Label("Agreed — see you there", systemImage: "checkmark.circle.fill")
                    .font(Tokens.Typography.caption.weight(.medium))
                    .foregroundStyle(Tokens.Palette.textPrimary)
                    .padding(.vertical, Tokens.Spacing.s2)
                    .padding(.horizontal, Tokens.Spacing.s3)
                    .background(Tokens.Palette.surfaceSecondary, in: Capsule())
                Spacer(minLength: 40)
            }
        }
        .padding(Tokens.Spacing.s3)
        .background(Tokens.Palette.surface.opacity(0.6),
                    in: RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("An iMessage conversation showing a Tween spot you sent and \(friendName) agreeing.")
    }

    /// A strip of map with two pins and the fair spot between them.
    private var miniMap: some View {
        GeometryReader { proxy in
            ZStack {
                RoundedRectangle(cornerRadius: Tokens.Radius.chip, style: .continuous)
                    .fill(.white.opacity(0.18))
                Path { path in
                    path.move(to: CGPoint(x: proxy.size.width * 0.10, y: proxy.size.height * 0.75))
                    path.addLine(to: CGPoint(x: proxy.size.width * 0.90, y: proxy.size.height * 0.30))
                }
                .stroke(.white.opacity(0.6), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [6, 5]))
                pin(Tokens.Palette.onBrand, "person.fill")
                    .position(x: proxy.size.width * 0.16, y: proxy.size.height * 0.68)
                pin(Tokens.Palette.pinFriend, "person.fill")
                    .position(x: proxy.size.width * 0.84, y: proxy.size.height * 0.34)
                pin(Tokens.Palette.pinFair, "star.fill")
                    .position(x: proxy.size.width * 0.50, y: proxy.size.height * 0.50)
            }
        }
    }

    private func pin(_ color: Color, _ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(color == Tokens.Palette.onBrand ? Tokens.Palette.pinSelf : .white)
            .frame(width: 20, height: 20)
            .background(color, in: Circle())
            .overlay(Circle().strokeBorder(.white, lineWidth: 1.5))
    }
}

#Preview {
    ChatIllustration()
        .padding()
        .background(Color.black)
}
