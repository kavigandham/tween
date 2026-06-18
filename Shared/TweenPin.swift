import SwiftUI

/// A map marker for a participant or computed spot.
///
/// Four roles, each a colored fill behind a white SF Symbol wrapped in a faint
/// halo ring. The active-self and midpoint roles pulse to draw the eye. Styling
/// here is intentionally literal — design tokens arrive in a later phase.
struct TweenPin: View {
    enum Role {
        case selfDot
        case selfActive
        case friend
        case midpoint

        var fill: Color {
            switch self {
            case .selfDot:    return .blue
            case .selfActive: return .green
            case .friend:     return .orange
            case .midpoint:   return .teal
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

        /// The midpoint reads as the goal, so it sits larger than the people pins.
        var diameter: CGFloat {
            self == .midpoint ? 44 : 32
        }

        var pulses: Bool {
            self == .selfActive || self == .midpoint
        }
    }

    let role: Role

    var body: some View {
        ZStack {
            Circle()
                .stroke(role.fill.opacity(0.3), lineWidth: 2)
                .frame(width: role.diameter + 10, height: role.diameter + 10)
            Circle()
                .fill(role.fill)
                .frame(width: role.diameter, height: role.diameter)
                .shadow(radius: 2, y: 1)
            icon
        }
    }

    @ViewBuilder
    private var icon: some View {
        let glyph = Image(systemName: role.symbol)
            .font(.system(size: role.diameter * 0.42, weight: .bold))
            .foregroundStyle(.white)
        if role.pulses {
            glyph.symbolEffect(.pulse)
        } else {
            glyph
        }
    }
}

#Preview {
    HStack(spacing: 24) {
        TweenPin(role: .selfDot)
        TweenPin(role: .selfActive)
        TweenPin(role: .friend)
        TweenPin(role: .midpoint)
    }
    .padding()
}
