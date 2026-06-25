import SwiftUI

private enum TutorialVisual {
    case join
    case fairSpot
    case messages
    case directions
}

private struct TutorialSlide: Identifiable {
    let id: String
    let eyebrow: String
    let title: String
    let body: String
    let accent: Color
    let visual: TutorialVisual
}

/// Swipeable help deck shown on first run and from the floating info button.
struct OnboardingTutorialView: View {
    var onDone: () -> Void

    private static let slides: [TutorialSlide] = [
        TutorialSlide(
            id: "join",
            eyebrow: "Step 1",
            title: "Tap I'm in",
            body: "Share your current spot, then your friend's spot appears as soon as they join from Messages or the app.",
            accent: Tokens.Palette.pinSelf,
            visual: .join
        ),
        TutorialSlide(
            id: "fair",
            eyebrow: "Step 2",
            title: "Pick a fair place",
            body: "Tween looks between both people and ranks places by travel time, so one person is not stuck with the whole drive.",
            accent: Tokens.Palette.pinFair,
            visual: .fairSpot
        ),
        TutorialSlide(
            id: "messages",
            eyebrow: "Step 3",
            title: "Send it to chat",
            body: "Share the spot back into iMessage. The app and extension keep the same meetup state.",
            accent: Tokens.Palette.brand,
            visual: .messages
        ),
        TutorialSlide(
            id: "directions",
            eyebrow: "Step 4",
            title: "Go, or tap I'm out",
            body: "Open Apple Maps or Google Maps for directions. If plans change, I'm out clears your side everywhere.",
            accent: Tokens.Palette.pinFriend,
            visual: .directions
        )
    ]

    @State private var selection = 0
    @State private var demoJoined = false
    @State private var demoChosen = false
    @State private var demoSent = false
    @State private var demoDirections = false

    private var isLastSlide: Bool { selection == Self.slides.count - 1 }

    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground)
                .ignoresSafeArea()

            VStack(spacing: Tokens.Spacing.s4) {
                header

                TabView(selection: $selection) {
                    ForEach(Array(Self.slides.enumerated()), id: \.element.id) { index, slide in
                        TutorialSlideView(
                            slide: slide,
                            demoJoined: $demoJoined,
                            demoChosen: $demoChosen,
                            demoSent: $demoSent,
                            demoDirections: $demoDirections
                        )
                        .tag(index)
                        .padding(.horizontal, Tokens.Spacing.s5)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                footer
            }
            .padding(.top, Tokens.Spacing.s4)
            .padding(.bottom, Tokens.Spacing.s6)
        }
        .sensoryFeedback(.selection, trigger: selection)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: Tokens.Spacing.s1) {
                Text("Tween guide")
                    .font(Tokens.Typography.captionBold)
                    .foregroundStyle(Tokens.Palette.brand)
                    .textCase(.uppercase)
                Text("How to meet halfway")
                    .font(Tokens.Typography.title2.weight(.bold))
                    .foregroundStyle(Tokens.Palette.textPrimary)
            }

            Spacer()

            Button(action: onDone) {
                Image(systemName: "xmark")
                    .font(Tokens.Typography.headline)
                    .foregroundStyle(Tokens.Palette.textPrimary)
                    .frame(width: Tokens.Layout.minTapTarget, height: Tokens.Layout.minTapTarget)
                    .background(Tokens.Palette.surfaceSecondary, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close guide")
        }
        .padding(.horizontal, Tokens.Spacing.s5)
    }

    private var footer: some View {
        VStack(spacing: Tokens.Spacing.s4) {
            HStack(spacing: Tokens.Spacing.s2) {
                ForEach(Self.slides.indices, id: \.self) { index in
                    Button {
                        withAnimation(Tokens.Motion.snappy) { selection = index }
                    } label: {
                        Capsule()
                            .fill(index == selection ? Self.slides[index].accent : Tokens.Palette.textTertiary.opacity(0.28))
                            .frame(width: index == selection ? 28 : 8, height: 8)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Go to guide step \(index + 1)")
                }

                Text("\(selection + 1)/\(Self.slides.count)")
                    .font(Tokens.Typography.captionBold)
                    .foregroundStyle(Tokens.Palette.textSecondary)
                    .padding(.leading, Tokens.Spacing.s1)
            }

            HStack(spacing: Tokens.Spacing.s3) {
                Button {
                    withAnimation(Tokens.Motion.snappy) {
                        selection = max(0, selection - 1)
                    }
                } label: {
                    Label("Back", systemImage: "chevron.left")
                }
                .buttonStyle(.tweenPrimary(.subtle))
                .disabled(selection == 0)

                Button {
                    if isLastSlide {
                        onDone()
                    } else {
                        withAnimation(Tokens.Motion.snappy) { selection += 1 }
                    }
                } label: {
                    Label(isLastSlide ? "Done" : "Next", systemImage: isLastSlide ? "checkmark" : "chevron.right")
                }
                .buttonStyle(.tweenPrimary())
            }
            .padding(.horizontal, Tokens.Spacing.s5)
        }
    }
}

private struct TutorialSlideView: View {
    let slide: TutorialSlide
    @Binding var demoJoined: Bool
    @Binding var demoChosen: Bool
    @Binding var demoSent: Bool
    @Binding var demoDirections: Bool

    var body: some View {
        VStack(spacing: Tokens.Spacing.s5) {
            Spacer(minLength: Tokens.Spacing.s2)

            TutorialVisualCard(
                slide: slide,
                demoJoined: $demoJoined,
                demoChosen: $demoChosen,
                demoSent: $demoSent,
                demoDirections: $demoDirections
            )
            .frame(maxHeight: 340)

            VStack(spacing: Tokens.Spacing.s3) {
                Text(slide.eyebrow)
                    .font(Tokens.Typography.captionBold)
                    .foregroundStyle(slide.accent)
                    .textCase(.uppercase)
                Text(slide.title)
                    .font(Tokens.Typography.display)
                    .foregroundStyle(Tokens.Palette.textPrimary)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.78)
                Text(slide.body)
                    .font(Tokens.Typography.body)
                    .foregroundStyle(Tokens.Palette.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .padding(.horizontal, Tokens.Spacing.s2)
            }

            Spacer(minLength: Tokens.Spacing.s2)
        }
        .accessibilityElement(children: .contain)
    }
}

private struct TutorialVisualCard: View {
    let slide: TutorialSlide
    @Binding var demoJoined: Bool
    @Binding var demoChosen: Bool
    @Binding var demoSent: Bool
    @Binding var demoDirections: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Tokens.Radius.sheet, style: .continuous)
                .fill(Tokens.Palette.surfaceSecondary)
            RoundedRectangle(cornerRadius: Tokens.Radius.sheet, style: .continuous)
                .strokeBorder(slide.accent.opacity(0.28), lineWidth: 1)

            switch slide.visual {
            case .join:
                joinVisual
            case .fairSpot:
                fairSpotVisual
            case .messages:
                messagesVisual
            case .directions:
                directionsVisual
            }
        }
        .tweenElevation(.sheet)
    }

    private var joinVisual: some View {
        VStack(spacing: Tokens.Spacing.s5) {
            MiniMap(showSelf: true, showFriend: demoJoined, showMidpoint: demoJoined)
                .frame(height: 150)
            Button {
                withAnimation(Tokens.Motion.spring) { demoJoined.toggle() }
            } label: {
                Label(demoJoined ? "You're in" : "Try I'm in", systemImage: demoJoined ? "checkmark.circle.fill" : "location.fill")
            }
            .buttonStyle(.tweenPrimary())
            .padding(.horizontal, Tokens.Spacing.s5)
        }
        .padding(Tokens.Spacing.s5)
    }

    private var fairSpotVisual: some View {
        VStack(spacing: Tokens.Spacing.s4) {
            MiniMap(showSelf: true, showFriend: true, showMidpoint: true)
                .frame(height: 128)
            Button {
                withAnimation(Tokens.Motion.spring) { demoChosen.toggle() }
            } label: {
                HStack {
                    Image(systemName: demoChosen ? "star.fill" : "star")
                        .foregroundStyle(Tokens.Palette.pinFair)
                    VStack(alignment: .leading, spacing: Tokens.Spacing.s1) {
                        Text(demoChosen ? "Sawmill Cafe selected" : "Tap a fair spot")
                            .font(Tokens.Typography.headline)
                            .foregroundStyle(Tokens.Palette.textPrimary)
                        Text("A 18 min · B 21 min")
                            .font(Tokens.Typography.captionBold)
                            .foregroundStyle(Tokens.Palette.textSecondary)
                    }
                    Spacer()
                }
                .padding(Tokens.Spacing.s4)
                .background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: Tokens.Radius.card))
            }
            .buttonStyle(.plain)
        }
        .padding(Tokens.Spacing.s5)
    }

    private var messagesVisual: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s3) {
            MessageBubble(text: "Where should we meet?", isOutgoing: true)
            HStack(spacing: Tokens.Spacing.s3) {
                MiniMap(showSelf: true, showFriend: true, showMidpoint: true)
                    .frame(width: 82, height: 82)
                    .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous))
                VStack(alignment: .leading, spacing: Tokens.Spacing.s1) {
                    Text("Sawmill Cafe")
                        .font(Tokens.Typography.headline)
                    Text(demoSent ? "Sent to chat" : "Ready to share")
                        .font(Tokens.Typography.caption)
                        .foregroundStyle(Tokens.Palette.textSecondary)
                }
                Spacer()
            }
            .padding(Tokens.Spacing.s3)
            .background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: Tokens.Radius.card))
            Button {
                withAnimation(Tokens.Motion.spring) { demoSent.toggle() }
            } label: {
                Label(demoSent ? "Shared" : "Send to chat", systemImage: demoSent ? "checkmark" : "paperplane.fill")
            }
            .buttonStyle(.tweenPrimary())
        }
        .padding(Tokens.Spacing.s5)
    }

    private var directionsVisual: some View {
        VStack(spacing: Tokens.Spacing.s4) {
            HStack(spacing: Tokens.Spacing.s3) {
                DirectionChip(title: "Apple Maps", systemImage: "map", isSelected: demoDirections)
                DirectionChip(title: "Google Maps", systemImage: "globe", isSelected: demoDirections)
            }
            Button {
                withAnimation(Tokens.Motion.spring) { demoDirections.toggle() }
            } label: {
                Label(demoDirections ? "Directions ready" : "Try directions", systemImage: "arrow.turn.up.right")
            }
            .buttonStyle(.tweenPrimary())

            Button {} label: {
                Label("I'm out", systemImage: "xmark.circle")
            }
            .buttonStyle(.tweenPrimary(.subtle))
        }
        .padding(Tokens.Spacing.s5)
    }
}

private struct MiniMap: View {
    let showSelf: Bool
    let showFriend: Bool
    let showMidpoint: Bool

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
                    .fill(Tokens.Palette.brandLight)

                Path { path in
                    path.move(to: CGPoint(x: proxy.size.width * 0.12, y: proxy.size.height * 0.78))
                    path.addCurve(
                        to: CGPoint(x: proxy.size.width * 0.88, y: proxy.size.height * 0.28),
                        control1: CGPoint(x: proxy.size.width * 0.36, y: proxy.size.height * 0.62),
                        control2: CGPoint(x: proxy.size.width * 0.62, y: proxy.size.height * 0.18)
                    )
                }
                .stroke(Tokens.Palette.textTertiary.opacity(0.45), style: StrokeStyle(lineWidth: 6, lineCap: .round))

                Path { path in
                    path.move(to: CGPoint(x: proxy.size.width * 0.08, y: proxy.size.height * 0.24))
                    path.addLine(to: CGPoint(x: proxy.size.width * 0.94, y: proxy.size.height * 0.68))
                }
                .stroke(Color.white.opacity(0.7), style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [10, 8]))

                if showSelf {
                    TutorialPin(color: Tokens.Palette.pinSelf, symbol: "person.fill")
                        .position(x: proxy.size.width * 0.24, y: proxy.size.height * 0.68)
                }
                if showFriend {
                    TutorialPin(color: Tokens.Palette.pinFriend, symbol: "person.fill")
                        .position(x: proxy.size.width * 0.76, y: proxy.size.height * 0.34)
                        .transition(.scale.combined(with: .opacity))
                }
                if showMidpoint {
                    TutorialPin(color: Tokens.Palette.pinFair, symbol: "star.fill")
                        .position(x: proxy.size.width * 0.50, y: proxy.size.height * 0.50)
                        .transition(.scale.combined(with: .opacity))
                }
            }
        }
    }
}

private struct TutorialPin: View {
    let color: Color
    let symbol: String

    var body: some View {
        Image(systemName: symbol)
            .font(Tokens.Typography.captionBold)
            .foregroundStyle(.white)
            .frame(width: 42, height: 42)
            .background(color, in: Circle())
            .overlay {
                Circle().strokeBorder(.white, lineWidth: 3)
            }
            .tweenElevation(.pin)
    }
}

private struct MessageBubble: View {
    let text: String
    let isOutgoing: Bool

    var body: some View {
        Text(text)
            .font(Tokens.Typography.callout)
            .foregroundStyle(isOutgoing ? .white : Tokens.Palette.textPrimary)
            .padding(.vertical, Tokens.Spacing.s3)
            .padding(.horizontal, Tokens.Spacing.s4)
            .frame(maxWidth: .infinity, alignment: isOutgoing ? .trailing : .leading)
            .background(isOutgoing ? Tokens.Palette.pinSelf : Color(uiColor: .systemBackground), in: Capsule())
    }
}

private struct DirectionChip: View {
    let title: String
    let systemImage: String
    let isSelected: Bool

    var body: some View {
        VStack(spacing: Tokens.Spacing.s2) {
            Image(systemName: systemImage)
                .font(Tokens.Typography.title2)
            Text(title)
                .font(Tokens.Typography.captionBold)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .foregroundStyle(isSelected ? .white : Tokens.Palette.brand)
        .frame(maxWidth: .infinity, minHeight: 92)
        .background(isSelected ? Tokens.Palette.brand : Tokens.Palette.brandLight, in: RoundedRectangle(cornerRadius: Tokens.Radius.card))
    }
}

#Preview {
    OnboardingTutorialView(onDone: {})
}
