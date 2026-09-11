import SwiftUI
import UIKit

/// The picture on a referral bubble: two people, the fair spot between them
/// (invite), or a check for "I'm on Tween" (joined). Rendered to an image
/// once per send — both processes can afford a 600×360 bitmap for a moment.
struct ReferralBubbleArt: View {
    let kind: ReferralMessage.Kind

    var body: some View {
        ZStack {
            LinearGradient(colors: [Tokens.Palette.brand, Tokens.Palette.brand.opacity(0.72)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            switch kind {
            case .invite:
                GeometryReader { proxy in
                    let w = proxy.size.width, h = proxy.size.height
                    ZStack {
                        Path { path in
                            path.move(to: CGPoint(x: w * 0.18, y: h * 0.68))
                            path.addLine(to: CGPoint(x: w * 0.82, y: h * 0.32))
                        }
                        .stroke(.white.opacity(0.7), style: StrokeStyle(lineWidth: 4, lineCap: .round, dash: [10, 8]))
                        pin(Tokens.Palette.onBrand, "person.fill", tint: Tokens.Palette.brand)
                            .position(x: w * 0.18, y: h * 0.68)
                        pin(Tokens.Palette.pinFriend, "person.fill", tint: .white)
                            .position(x: w * 0.82, y: h * 0.32)
                        pin(Tokens.Palette.pinFair, "star.fill", tint: .white, size: 54)
                            .position(x: w * 0.5, y: h * 0.5)
                    }
                }
            case .joined:
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 88, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: 300, height: 180)
    }

    private func pin(_ fill: Color, _ symbol: String, tint: Color, size: CGFloat = 44) -> some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.42, weight: .bold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(fill, in: Circle())
            .overlay(Circle().strokeBorder(.white, lineWidth: 3))
    }

    @MainActor
    static func render(_ kind: ReferralMessage.Kind) -> UIImage? {
        let renderer = ImageRenderer(content: ReferralBubbleArt(kind: kind))
        renderer.scale = 2
        return renderer.uiImage
    }
}

/// "Hassan invited you — tell them you're on Tween." Shown by the Messages
/// extension when the tapped bubble is an invite this install hasn't
/// answered. One tap sends the `.joined` bubble that proves the install.
struct ReferralReplyPrompt {
    let inviterName: String
    let onReply: () -> Void
}

struct ReferralReplyBanner: View {
    let prompt: ReferralReplyPrompt
    var isSending = false

    /// Nil when the inviter never set a name — the copy then says "A friend"
    /// and "Tell them" rather than splitting a placeholder ("Your invited you").
    private var firstName: String? {
        let trimmed = prompt.inviterName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.split(separator: " ").first.map(String.init) ?? trimmed
    }

    var body: some View {
        HStack(spacing: Tokens.Spacing.s3) {
            Image(systemName: "gift.fill")
                .font(Tokens.Typography.headline)
                .foregroundStyle(Tokens.Palette.onBrand)
                .frame(width: 36, height: 36)
                .background(Tokens.Palette.brand, in: Circle())
            // The text wins the width; the button keeps its natural size.
            // A headline-weight title truncated to "Hassan invited…" beside
            // the button on a 6.1" phone.
            VStack(alignment: .leading, spacing: 2) {
                Text(firstName.map { "\($0) invited you" } ?? "A friend invited you")
                    .font(Tokens.Typography.subheadline.weight(.semibold))
                    .foregroundStyle(Tokens.Palette.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Text("Let them know you joined")
                    .font(Tokens.Typography.caption)
                    .foregroundStyle(Tokens.Palette.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .layoutPriority(1)
            Spacer(minLength: 0)
            Button(action: prompt.onReply) {
                Text(isSending ? "Sending…" : "Tell \(firstName ?? "them")")
                    .font(Tokens.Typography.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .padding(.horizontal, Tokens.Spacing.s3)
                    .frame(minHeight: 36)
                    .foregroundStyle(Tokens.Palette.onBrand)
                    .background(Tokens.Palette.brand, in: Capsule())
            }
            .buttonStyle(.plain)
            .fixedSize()
            .disabled(isSending)
            .accessibilityHint("Sends \(firstName ?? "your friend") a Tween message saying you've installed it")
        }
        .padding(Tokens.Spacing.s3)
        .background(Tokens.Palette.brandLight,
                    in: RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous))
    }
}

/// A ring that fills in thirds — referral progress at a glance.
struct ReferralProgressRing: View {
    let filled: Int
    var total = ReferralPolicy.required
    var size: CGFloat = 44

    var body: some View {
        ZStack {
            Circle()
                .stroke(Tokens.Palette.elevatedStrong, lineWidth: 4)
            Circle()
                .trim(from: 0, to: CGFloat(min(filled, total)) / CGFloat(total))
                .stroke(Tokens.Palette.brand, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Image(systemName: "gift.fill")
                .font(.system(size: size * 0.36, weight: .semibold))
                .foregroundStyle(Tokens.Palette.brand)
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(filled) of \(total) friends joined")
    }
}
