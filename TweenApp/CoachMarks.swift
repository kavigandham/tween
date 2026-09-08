import SwiftUI

/// The interactive first-run tour: a dimmed layer over the LIVE app with a
/// spotlight cut around the real control, a short callout, and taps that
/// pass through only inside the spotlight. Each step advances when the user
/// actually does the thing (taps I'm in, taps Coffee, opens a spot…), so by
/// the end they have used the app once rather than read about it.
///
/// Replaces the swipeable slide deck as the launch experience (product
/// decision 2026-09-06: "circles around buttons that you have to click"). The
/// deck survives in Settings because it explains the Messages-drawer side of
/// Tween, which a tour of the host app cannot show.
///
/// Two overlays, one per presentation layer: the map ZStack and the bottom
/// sheet are separate UIKit presentations, so neither can draw over the
/// other. Both dim; only the layer that CONTAINS the step's target cuts the
/// spotlight and shows the callout. Steps with no target show their card in
/// the sheet layer, where the eye already is.
enum TourStep: Int, CaseIterable, Equatable {
    case welcome
    case imIn
    case coffeeChip
    case openSpot
    /// INSIDE the place sheet: what every control on it does, then a way
    /// back. The tour must never leave the user on a screen it hasn't
    /// explained (product feedback 2026-09-08: "fully immersive, A to Z").
    case spotSheet
    case friends
    /// INSIDE the Friends sheet, same rule.
    case friendsSheet
    case mapControls
    case done

    var target: CoachTarget? {
        switch self {
        case .welcome, .done: return nil
        case .imIn:           return .imInButton
        case .coffeeChip:     return .coffeeChip
        case .openSpot:       return .firstResultCard
        case .spotSheet:      return .sendToChat
        case .friends:        return .friendsButton
        case .friendsSheet:   return .addFriend
        case .mapControls:    return .mapToolbar
        }
    }

    var title: String {
        switch self {
        case .welcome:      return "Welcome to Tween"
        case .imIn:         return "Tap I'm in"
        case .coffeeChip:   return "Find fair spots"
        case .openSpot:     return "Open a spot"
        case .spotSheet:    return "The place sheet"
        case .friends:      return "Your friends"
        case .friendsSheet: return "The Friends screen"
        case .mapControls:  return "Map controls"
        case .done:         return "You're set"
        }
    }

    var body: String {
        switch self {
        case .welcome:
            return "This is your map — the blue dot is you. The panel below is where you search, see who's in, and pick a place. Tween ranks spots by everyone's travel time, so nobody drives the long way. Here's a quick tour."
        case .imIn:
            return "Share where you are. Tween only uses your location while the app is open, and your friends only see it once you send them a spot."
        case .coffeeChip:
            return "Tap Coffee. Tween searches between everyone who's in and ranks places by how far each person travels. The other chips work the same way."
        case .openSpot:
            return "Each card shows a place, how far it is, and everyone's travel time. Tap the top card to open it."
        case .spotSheet:
            return "Everything about one spot. The tiles give you directions in your travel mode, a call, and the website. Send to chat drops the spot into iMessage so your friends can tap Agree — or suggest somewhere else. Add to Favorites keeps it handy; Plan sets a time and a calendar invite (Tween Pro)."
        case .friends:
            return "Tap here for your people."
        case .friendsSheet:
            return "Add Friend saves someone from Contacts so you can ping them to join. Invite shares Tween. Current meetup lists who's in right now. Groups remember your whole crew for one-tap planning (Tween Pro), and Rides tracks who needs a lift."
        case .mapControls:
            return "Recenter on yourself, or switch map styles. Drag the panel down any time to see more map, and up to see the full list."
        case .done:
            return "Search any place from the bar, or open Tween from the + in an iMessage chat to plan right there. This guide is always in the ⋯ menu."
        }
    }

    /// The button on steps the user advances themselves; nil when the step
    /// waits for a real tap on the spotlit control.
    var nextTitle: String? {
        switch self {
        case .welcome:      return "Start the tour"
        case .spotSheet:    return "Back to the map"
        case .friendsSheet: return "Back to the map"
        case .mapControls:  return "Next"
        case .done:         return "Finish"
        default:            return nil
        }
    }

    /// Steps whose Next button also CLOSES the sheet they live in.
    var closesSheetOnNext: Bool {
        self == .spotSheet || self == .friendsSheet
    }

    /// Where the callout (or the card, for target-less steps) renders.
    var layer: CoachLayer {
        target?.layer ?? .sheet
    }

    /// Steps the user must perform show a small "Tap it" hint instead of a
    /// Next button — the spotlit control IS the next button.
    var waitsForUser: Bool { nextTitle == nil }

    var ordinal: Int { rawValue + 1 }
    static var count: Int { allCases.count }
}

/// Which presentation the target lives in. Each is its own UIKit
/// presentation, so each hosts its own `CoachMarkOverlay`.
enum CoachLayer {
    case map
    case sheet
    /// The place sheet (`activeSheet == .spot`).
    case spot
    /// The Friends sheet (`activeSheet == .friends`).
    case friends
}

/// A spotlit control. Each attaches `.coachTarget(_:)` to its own view.
enum CoachTarget: Hashable {
    case imInButton
    case coffeeChip
    case firstResultCard
    case friendsButton
    case mapToolbar
    case sendToChat
    case addFriend

    var layer: CoachLayer {
        switch self {
        case .mapToolbar: return .map
        case .sendToChat: return .spot
        case .addFriend:  return .friends
        default:          return .sheet
        }
    }

    /// The spotlight follows the control's own shape: circles stay circles,
    /// capsules stay capsules, cards keep their corner radius.
    func cornerRadius(for size: CGSize) -> CGFloat {
        switch self {
        case .friendsButton:   return max(size.width, size.height) / 2
        case .coffeeChip:      return size.height / 2
        case .mapToolbar:      return size.width / 2
        case .imInButton:      return Tokens.Radius.action
        case .firstResultCard: return Tokens.Radius.card
        case .sendToChat:      return Tokens.Radius.action
        case .addFriend:       return Tokens.Radius.action
        }
    }
}

/// Collects target bounds from wherever the controls render. Anchors resolve
/// in the overlay's own coordinate space, so each layer sees its own targets.
struct CoachTargetKey: PreferenceKey {
    static var defaultValue: [CoachTarget: Anchor<CGRect>] = [:]
    static func reduce(value: inout [CoachTarget: Anchor<CGRect>],
                       nextValue: () -> [CoachTarget: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

extension View {
    /// Registers this view as a tour target. Nil is a no-op so a call site can
    /// tag one element of a ForEach (`item == first ? .firstResultCard : nil`).
    func coachTarget(_ target: CoachTarget?) -> some View {
        // One view type either way. An if/else here made the first result
        // row a different branch from its siblings, so every re-rank that
        // changed the first item tore two rows down and rebuilt them.
        anchorPreference(key: CoachTargetKey.self, value: .bounds) { anchor in
            target.map { [$0: anchor] } ?? [:]
        }
    }
}

/// Full-layer dim with an even-odd hole. Used for BOTH drawing and hit
/// testing, so taps land only through the spotlight.
private struct SpotlightShape: Shape {
    var hole: CGRect?
    var radius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path(rect)
        if let hole {
            path.addPath(Path(roundedRect: hole, cornerRadius: radius, style: .continuous))
        }
        return path
    }
}

/// One layer's slice of the tour. Renders nothing when `step` is nil.
struct CoachMarkOverlay: View {
    let step: TourStep?
    let layer: CoachLayer
    /// Where the callout draws this pass. The spotlight always cuts in the
    /// layer that owns the target, but the callout goes where it can be
    /// SEEN: the map layer, parked above the sheet's edge, whenever the sheet
    /// is not at full height (a peek sheet can't fit a card, and the map
    /// layer sits behind it); the sheet layer when the sheet covers the map.
    let calloutLayer: CoachLayer
    /// The sheet's measured top edge (global), so a map-layer callout can
    /// park just above it. Read HERE, in this small view, never in the
    /// home screen's body — it changes on every frame of a drag.
    let edge: SheetEdgeTracker
    let anchors: [CoachTarget: Anchor<CGRect>]
    let onNext: () -> Void
    let onSkip: () -> Void

    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Breathing room between the control's edge and the spotlight.
    private let inset: CGFloat = Tokens.Spacing.s2

    var body: some View {
        if let step {
            GeometryReader { geo in
                let hole = spotlight(for: step, in: geo)
                let radius = hole.map { step.target?.cornerRadius(for: $0.size) ?? 0 } ?? 0
                ZStack(alignment: .topLeading) {
                    // Dim + hole. Drawing and hit-testing share the shape, so
                    // the spotlit control receives the tap and nothing else
                    // beneath the dim does.
                    SpotlightShape(hole: hole, radius: radius)
                        .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
                        // The hole passes taps ONLY on steps that wait for
                        // the user's tap. An informational step (the sheet
                        // explainers) highlights a control without making it
                        // live — a tap on the spotlit Send would otherwise
                        // open the composer mid-explanation.
                        .contentShape(SpotlightShape(hole: step.waitsForUser ? hole : nil, radius: radius),
                                      eoFill: true)
                        .onTapGesture {}

                    if let hole {
                        // The ring that says "this one" — pulses gently unless
                        // Reduce Motion is on.
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .strokeBorder(Tokens.Palette.onBrand, lineWidth: 3)
                            .frame(width: hole.width, height: hole.height)
                            .scaleEffect(pulse && !reduceMotion ? 1.05 : 1)
                            .position(x: hole.midX, y: hole.midY)
                            .allowsHitTesting(false)
                            // Fresh ring per step, so the repeat-forever
                            // animation restarts instead of freezing mid-pulse.
                            .id(step)
                            .onAppear {
                                withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                                    pulse = true
                                }
                            }
                    }

                    if calloutLayer == layer {
                        callout(for: step, hole: hole, in: geo)
                    }
                }
                .animation(Tokens.Motion.snappy, value: hole)
                .animation(Tokens.Motion.snappy, value: edge.topGlobalY)
            }
            // Full-bleed dim; `geo[anchor]` resolves targets into THIS
            // proxy's space, so the spotlight stays aligned.
            .ignoresSafeArea()
            .transition(.opacity)
            // NOT `.isModal`: that scopes VoiceOver to the overlay's own
            // descendants, and the spotlit control is a sibling beneath it —
            // every performed step became Skip-only under VoiceOver (audit
            // 2026-09-06). The callout is announced on each step instead.
            .onChange(of: step, initial: true) { _, step in
                AccessibilityNotification.Announcement(
                    "Tour step \(step.ordinal) of \(TourStep.count). \(step.title). \(step.body)"
                ).post()
            }
        }
    }

    /// The target's bounds in this layer, grown by the inset; nil when the
    /// step targets the other layer (dim only) or has no target.
    private func spotlight(for step: TourStep, in geo: GeometryProxy) -> CGRect? {
        guard let target = step.target, target.layer == layer,
              let anchor = anchors[target] else { return nil }
        return geo[anchor].insetBy(dx: -inset, dy: -inset)
    }

    /// Below the spotlight when there is room, else above. With no spotlight
    /// in this layer: on the map, parked just above the sheet's edge (where
    /// the spotlit control or the sheet's content is); in the sheet, centred.
    @ViewBuilder
    private func callout(for step: TourStep, hole: CGRect?, in geo: GeometryProxy) -> some View {
        let card = calloutCard(for: step)
            .frame(maxWidth: 360)
            .padding(.horizontal, Tokens.Spacing.s4)
        if let hole {
            // Prefer below; a spotlight in the lower half flips the card above.
            let below = hole.midY < geo.size.height / 2
            card
                .frame(maxWidth: .infinity,
                       maxHeight: .infinity,
                       alignment: below ? .top : .bottom)
                .padding(.top, below ? hole.maxY + Tokens.Spacing.s4 : 0)
                .padding(.bottom, below ? 0 : geo.size.height - hole.minY + Tokens.Spacing.s4)
        } else if layer == .map {
            let mapBottom = geo.frame(in: .global).maxY
            let aboveSheet = edge.topGlobalY.map { max(mapBottom - $0, 0) } ?? 0
            card
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, aboveSheet + Tokens.Spacing.s4)
        } else {
            card
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }

    private func calloutCard(for step: TourStep) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s3) {
            HStack {
                Text("\(step.ordinal) of \(TourStep.count)")
                    .font(Tokens.Typography.captionBold)
                    .foregroundStyle(Tokens.Palette.textSecondary)
                Spacer(minLength: 0)
                Button("Skip", action: onSkip)
                    .font(Tokens.Typography.captionBold)
                    .foregroundStyle(Tokens.Palette.accent)
                    .accessibilityHint("Ends the tour")
            }
            Text(step.title)
                .font(Tokens.Typography.headline)
                .foregroundStyle(Tokens.Palette.textPrimary)
            Text(step.body)
                .font(Tokens.Typography.subheadline)
                .foregroundStyle(Tokens.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if let next = step.nextTitle {
                Button(action: onNext) {
                    Text(next)
                        .font(Tokens.Typography.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: Tokens.Layout.minTapTarget)
                }
                .buttonStyle(.tweenPrimary())
            } else {
                Label("Tap the highlighted control to continue", systemImage: "hand.tap")
                    .font(Tokens.Typography.footnote)
                    .foregroundStyle(Tokens.Palette.accent)
            }
        }
        .padding(Tokens.Spacing.s4)
        .background(Tokens.Palette.surface, in: RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous))
        .tweenElevation(.floating)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tour step \(step.ordinal) of \(TourStep.count): \(step.title). \(step.body)")
        // Read first, then the spotlit control, then everything else.
        .accessibilitySortPriority(1)
    }
}

