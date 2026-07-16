import SwiftUI

/// A map marker for a participant or computed spot.
///
/// Three visual families (device feedback: the old one-size colored blobs
/// with glyphs + faint halo rings read as "ugly and clunky"):
///  * **You** — Apple's own location-dot language: white-ringed blue dot,
///    with a soft halo while you're sharing.
///  * **People** — Find-My-style circular avatars: participant color, white
///    ring, the person's initials; a small car badge when they need a ride.
///  * **Spots** (fair spot, results) — compact white-ringed glyph circles.
///    Color is never the sole differentiator (accessibility).
struct TweenPin: View {
    enum Role {
        case selfDot
        case selfActive
        case friend
        case rideNeeded
        case fairSpot
        case midpoint
        case closestToUser
        case result

        var fill: Color {
            switch self {
            case .selfDot:       return Tokens.Palette.pinSelf
            case .selfActive:    return Tokens.Palette.pinSelfActive
            case .friend:        return Tokens.Palette.pinFriend
            case .rideNeeded:    return Tokens.Palette.pinRideNeeded
            case .fairSpot:      return Tokens.Palette.pinFair
            case .midpoint:      return Tokens.Palette.pinMidpoint
            case .closestToUser: return Tokens.Palette.pinClosest
            case .result:        return Tokens.Palette.pinResult
            }
        }

        var symbol: String {
            switch self {
            case .selfDot:       return "circle.fill"
            case .selfActive:    return "checkmark"
            case .friend:        return "person.fill"
            case .rideNeeded:    return "figure.wave"
            case .fairSpot:      return "star.fill"
            case .midpoint:      return "circle.fill"
            case .closestToUser: return "location.fill"
            case .result:        return "mappin"
            }
        }

        /// VoiceOver name for the marker.
        var accessibilityName: String {
            switch self {
            case .selfDot:       return "Your location"
            case .selfActive:    return "Your shared location"
            case .friend:        return "Your friend's location"
            case .rideNeeded:    return "Participant needs a ride"
            case .fairSpot:      return "Best fair meetup spot"
            case .midpoint:      return "Search midpoint"
            case .closestToUser: return "Place closest to you"
            case .result:        return "Search result"
            }
        }

        var diameter: CGFloat {
            switch self {
            case .fairSpot:
                return 42
            case .midpoint:
                return 18
            default:
                return 32
            }
        }

        /// Compact diameter for the extension's small static snapshot (audit
        /// F5): host-sized furniture cluttered a thumbnail map. Spot 28, result
        /// 22, avatars/self 24.
        var compactDiameter: CGFloat {
            switch self {
            case .fairSpot:      return 28
            case .midpoint:      return 14
            case .result:        return 22
            case .closestToUser: return 26
            default:             return 24
            }
        }

        func diameter(_ context: TweenPin.Context) -> CGFloat {
            context == .compact ? compactDiameter : diameter
        }
    }

    /// Render scale. Host surfaces stay `.regular`; the extension's small static
    /// snapshot draws `.compact` so pins don't clutter a thumbnail map (F5).
    enum Context {
        case regular
        case compact
    }

    let role: Role
    /// Person initials shown inside avatar pins (friend / ride roles). Nil
    /// falls back to a person glyph so legacy call sites keep rendering.
    var initials: String? = nil
    /// Adds the small car badge as an ORTHOGONAL overlay on whichever family
    /// the role renders — the You dot stays a You dot when you need a ride,
    /// instead of turning into an anonymous friend avatar (post-push audit
    /// at 42fdc68). The legacy `.rideNeeded` role keeps working: it renders
    /// the avatar family with the badge forced on.
    var needsRide: Bool = false
    /// When false, animated effects are suppressed — pass `false` anywhere a
    /// continuously animating glyph would keep a render loop hot (the host
    /// app's live map is the only live-map user; the extension is
    /// snapshotter-only).
    var animated: Bool = true

    /// "Hassan Ahmed" → "HA"; single names give one letter. Shared so the
    /// host map and extension map agree on avatars.
    static func initials(for name: String) -> String {
        let letters = name.split(separator: " ").prefix(2)
            .compactMap { $0.first.map(String.init) }
        return letters.joined().uppercased()
    }

    var body: some View {
        pin
            .transition(.scale.combined(with: .opacity))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabelText)
    }

    /// The car badge is sighted-only, so the ride state must ride the label —
    /// dropping it when the badge replaced the `.rideNeeded` role made ride
    /// status invisible to VoiceOver (audit at 2b894b0). `.rideNeeded`'s own
    /// name already announces it, so avoid the duplicate suffix there.
    private var accessibilityLabelText: String {
        needsRide && role != .rideNeeded
            ? role.accessibilityName + ", needs a ride"
            : role.accessibilityName
    }

    @ViewBuilder
    private var pin: some View {
        switch role {
        case .selfDot, .selfActive:
            selfDot
        case .friend, .rideNeeded:
            avatar
        case .midpoint:
            midpointDot
        case .fairSpot, .closestToUser, .result:
            glyphCircle
        }
    }

    // MARK: - You: the classic location dot

    private var selfDot: some View {
        ZStack(alignment: .bottomTrailing) {
            ZStack {
                if role == .selfActive {
                    Circle()
                        .fill(Tokens.Palette.pinSelf.opacity(0.18))
                        .frame(width: 46, height: 46)
                }
                Circle()
                    .fill(.white)
                    .frame(width: 26, height: 26)
                    .tweenElevation(.pin)
                Circle()
                    .fill(Tokens.Palette.pinSelf)
                    .frame(width: 19, height: 19)
            }
            if needsRide {
                rideBadge
                    .offset(x: 5, y: 5)
            }
        }
    }

    // MARK: - People: Find-My-style avatars

    private var avatar: some View {
        ZStack(alignment: .bottomTrailing) {
            ZStack {
                Circle().fill(Tokens.Palette.pinFriend)
                if let initials, !initials.isEmpty {
                    Text(initials)
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .minimumScaleFactor(0.7)
                } else {
                    Image(systemName: "person.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 38, height: 38)
            .overlay(Circle().strokeBorder(.white, lineWidth: 2.5))
            .tweenElevation(.pin)

            if needsRide || role == .rideNeeded {
                rideBadge
                    .offset(x: 3, y: 3)
            }
        }
    }

    private var rideBadge: some View {
        ZStack {
            Circle().fill(.white)
            Image(systemName: "car.fill")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Tokens.Palette.pinRideNeeded)
        }
        .frame(width: 17, height: 17)
    }

    // MARK: - Spots: compact glyph circles

    private var midpointDot: some View {
        Circle()
            .fill(role.fill)
            .frame(width: role.diameter, height: role.diameter)
            .overlay(Circle().strokeBorder(.white.opacity(0.92), lineWidth: 2))
            .tweenElevation(.pin)
    }

    private var glyphCircle: some View {
        ZStack {
            Circle()
                .fill(role.fill)
                .frame(width: role.diameter, height: role.diameter)
                .overlay(Circle().strokeBorder(.white.opacity(0.92), lineWidth: 2))
                .tweenElevation(.pin)
            Image(systemName: role.symbol)
                .font(.system(size: role.diameter * 0.42, weight: .bold))
                .foregroundStyle(.white)
        }
    }
}

#Preview {
    HStack(spacing: Tokens.Spacing.s6) {
        TweenPin(role: .selfDot)
        TweenPin(role: .selfActive)
        TweenPin(role: .friend, initials: "SA")
        TweenPin(role: .rideNeeded, initials: "KG")
        TweenPin(role: .fairSpot)
        TweenPin(role: .midpoint)
        TweenPin(role: .closestToUser)
        TweenPin(role: .result)
    }
    .padding()
}
