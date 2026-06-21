import SwiftUI

/// A map marker for a participant or computed spot.
///
/// Map roles, each a colored fill behind a white SF Symbol wrapped in a faint
/// halo ring. The active-self role pulses to draw the eye. Color
/// and elevation flow from `Tokens`; each role also carries a distinct glyph so
/// color is never the sole differentiator (accessibility).
struct TweenPin: View {
    enum Role {
        case selfDot
        case selfActive
        case friend
        case fairSpot
        case closestToUser
        case result
        case midpoint

        var fill: Color {
            switch self {
            case .selfDot:       return Tokens.Palette.pinSelf
            case .selfActive:    return Tokens.Palette.pinSelfActive
            case .friend:        return Tokens.Palette.pinFriend
            case .fairSpot:      return Tokens.Palette.pinFair
            case .closestToUser: return Tokens.Palette.pinClosest
            case .result:        return Tokens.Palette.pinResult
            case .midpoint:      return Tokens.Palette.pinMidpoint
            }
        }

        var symbol: String {
            switch self {
            case .selfDot:       return "circle.fill"
            case .selfActive:    return "checkmark"
            case .friend:        return "square.fill"
            case .fairSpot:      return "star.fill"
            case .closestToUser: return "location.fill"
            case .result:        return "mappin"
            case .midpoint:      return "diamond.fill"
            }
        }

        /// VoiceOver name for the marker.
        var accessibilityName: String {
            switch self {
            case .selfDot:       return "Your location"
            case .selfActive:    return "Your shared location"
            case .friend:        return "Your friend's location"
            case .fairSpot:      return "Best fair meetup spot"
            case .closestToUser: return "Place closest to you"
            case .result:        return "Search result"
            case .midpoint:      return "Geographic midpoint"
            }
        }

        var diameter: CGFloat {
            switch self {
            case .fairSpot:
                return 42
            case .midpoint:
                return 28
            default:
                return 32
            }
        }

        var pulses: Bool {
            self == .selfActive
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
        TweenPin(role: .fairSpot)
        TweenPin(role: .closestToUser)
        TweenPin(role: .result)
    }
    .padding()
}
