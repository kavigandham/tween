import SwiftUI

/// A map marker for a participant or computed spot.
///
/// Four roles, each a colored fill behind a white SF Symbol wrapped in a faint
/// halo ring. The active-self and midpoint roles pulse to draw the eye. Color
/// and elevation flow from `Tokens`; each role also carries a distinct glyph so
/// color is never the sole differentiator (accessibility).
struct TweenPin: View {
    enum Role {
        case selfDot
        case selfActive
        case friend
        case midpoint

        var fill: Color {
            switch self {
            case .selfDot:    return Tokens.Palette.pinSelf
            case .selfActive: return Tokens.Palette.pinSelfActive
            case .friend:     return Tokens.Palette.pinFriend
            case .midpoint:   return Tokens.Palette.pinMidpoint
            }
        }

        var symbol: String {
            switch self {
            case .selfDot:    return "circle.fill"
            case .selfActive: return "checkmark"
            case .friend:     return "square.fill"
            case .midpoint:   return "star.fill"
            }
        }

        /// VoiceOver name for the marker.
        var accessibilityName: String {
            switch self {
            case .selfDot:    return "Your location"
            case .selfActive: return "Your shared location"
            case .friend:     return "Your friend's location"
            case .midpoint:   return "Fair midpoint"
            }
        }

        /// The midpoint reads as the goal, so it sits larger than the people pins.
        var diameter: CGFloat {
            self == .midpoint ? 44 : 32
        }

        var pulses: Bool {
            self == .selfActive || self == .midpoint
        }
    }

    let role: Role
    /// When false, the `.pulse` symbol effect is suppressed. The extension's live
    /// `Map` passes `false` so a continuously animating glyph doesn't keep
    /// `MKMapView`'s render loop hot (memory/GPU pressure under the ~120 MB ceiling).
    var animated: Bool = true

    var body: some View {
        ZStack {
            Circle()
                .stroke(role.fill.opacity(0.3), lineWidth: 2)
                .frame(width: role.diameter + 10, height: role.diameter + 10)
            Circle()
                .fill(role.fill)
                .frame(width: role.diameter, height: role.diameter)
                .tweenElevation(.pin)
            icon
        }
        .transition(.scale.combined(with: .opacity))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(role.accessibilityName)
    }

    @ViewBuilder
    private var icon: some View {
        // Glyph size is intrinsically proportional to the pin diameter, so it
        // tracks the geometry token rather than a fixed typography token.
        let glyph = Image(systemName: role.symbol)
            .font(.system(size: role.diameter * 0.42, weight: .bold))
            .foregroundStyle(.white)
        if role.pulses && animated {
            glyph.symbolEffect(.pulse, isActive: true)
        } else {
            glyph
        }
    }
}

#Preview {
    HStack(spacing: Tokens.Spacing.s6) {
        TweenPin(role: .selfDot)
        TweenPin(role: .selfActive)
        TweenPin(role: .friend)
        TweenPin(role: .midpoint)
    }
    .padding()
}
