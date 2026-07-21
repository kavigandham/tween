import SwiftUI
import UIKit
import MapKit
import CoreLocation

struct CompactView: View {
    let received: TweenState?
    let isUserIn: Bool
    var localParticipantID: String? = nil
    /// The controller's live roster count (self included once joined). The
    /// decoded `received` bubble lags one message behind — it can't include
    /// the local user's own just-sent join — so pills prefer this when set.
    /// Nil keeps the legacy received-derived rendering.
    var currentParticipantCount: Int? = nil
    var isSending: Bool = false
    var statusMessage: String?
    var onImIn: () -> Void
    var onImOut: () -> Void = {}
    var onExpand: () -> Void

    var body: some View {
        VStack(spacing: Tokens.Spacing.s3) {
            if received == nil {
                launcherState
            } else {
                activeMeetupState
            }
        }
        // Tight vertical padding: the compact surface is only keyboard height,
        // and every point of chrome comes out of the content's budget.
        .padding(.horizontal, Tokens.Spacing.s4)
        .padding(.vertical, Tokens.Spacing.s2)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Opaque background so the compact strip never reads as transparent
        // against the iMessage keyboard backdrop. systemBackground tracks
        // light/dark mode automatically.
        .background(Color(.systemBackground))
        // The whole surface expands; the real Button below intercepts its own taps.
        .contentShape(Rectangle())
        .onTapGesture(perform: onExpand)
        // No `.accessibilityElement(children: .combine)` here — collapsing the
        // surface into one element made the nested I'm in / I'm out / Browse
        // buttons unreachable to VoiceOver. The custom action mirrors the
        // background tap instead.
        .accessibilityAction(named: "Open Tween", onExpand)
    }

    private var launcherState: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s3) {
            HStack(spacing: Tokens.Spacing.s3) {
                compactAppIcon

                VStack(alignment: .leading, spacing: 2) {
                    Text(isUserIn ? "You're in" : "Start a meetup")
                        .font(Tokens.Typography.headline)
                        .foregroundStyle(Tokens.Palette.textPrimary)
                    Text(isUserIn ? "Waiting for others." : "Share in this chat.")
                        .font(Tokens.Typography.caption)
                        .foregroundStyle(Tokens.Palette.textSecondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                rosterCountPill
            }

            compactPrimaryAction

            // Delivery status (e.g. the insert-fallback's "tap send to
            // deliver" hint, or a send failure) — the launcher previously had
            // no status surface at all, so staged sends looked like silence.
            if let statusMessage, !isSending {
                Text(statusMessage)
                    .font(Tokens.Typography.caption)
                    .foregroundStyle(Tokens.Palette.textSecondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: Tokens.Spacing.s2) {
                Button(action: onExpand) {
                    Label("Browse", systemImage: "arrow.up.forward.app")
                        .font(Tokens.Typography.captionBold)
                        .frame(maxWidth: .infinity, minHeight: Tokens.Layout.minTapTarget)
                }
                .buttonStyle(.tweenPrimary(.subtle))

                if isUserIn {
                    Button(action: onImOut) {
                        Label("I'm out", systemImage: "location.slash")
                            .font(Tokens.Typography.captionBold)
                            .frame(maxWidth: .infinity, minHeight: Tokens.Layout.minTapTarget)
                    }
                    .buttonStyle(.tweenPrimary(.destructive))
                    // handleImOut drops taps while a send is in flight (the
                    // double-fire guard) — reflect that instead of looking
                    // tappable and doing nothing (post-push verify).
                    .disabled(isSending)
                    .accessibilityHint("Stops sharing you as active for this meetup")
                } else {
                    Button(action: onExpand) {
                        Label("Details", systemImage: "person.2")
                            .font(Tokens.Typography.captionBold)
                            .frame(maxWidth: .infinity, minHeight: Tokens.Layout.minTapTarget)
                    }
                    .buttonStyle(.tweenPrimary(.subtle))
                }
            }
        }
        .padding(Tokens.Spacing.s3)
        .background(Tokens.Palette.surfaceSecondary, in: RoundedRectangle(cornerRadius: Tokens.Radius.sheet, style: .continuous))
    }

    private var activeMeetupState: some View {
        VStack(spacing: Tokens.Spacing.s3) {
            Button(action: onExpand) {
                HStack(spacing: Tokens.Spacing.s4) {
                    thumbnail
                    VStack(alignment: .leading, spacing: Tokens.Spacing.s2) {
                        Text(title)
                            .font(Tokens.Typography.headline)
                            .foregroundStyle(Tokens.Palette.textPrimary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Text(subtitle)
                            .font(Tokens.Typography.callout)
                            .foregroundStyle(Tokens.Palette.textSecondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        HStack(spacing: Tokens.Spacing.s2) {
                            statusPill
                            compactRoster
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(Tokens.Spacing.s3)
                .background(Tokens.Palette.surfaceSecondary, in: RoundedRectangle(cornerRadius: Tokens.Radius.sheet, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: Tokens.Radius.sheet, style: .continuous)
                        .strokeBorder(Tokens.Palette.brand.opacity(0.18), lineWidth: 1)
                }
            }
            .buttonStyle(.plain)

            compactPrimaryAction

            // Secondary row only while in: Browse + I'm out. When not in, the
            // card tap and the "I'm in" CTA cover both actions, and dropping
            // the row keeps the stack inside the keyboard-height budget.
            if isUserIn {
                HStack(spacing: Tokens.Spacing.s2) {
                    Button(action: onExpand) {
                        Label(received?.kind == .place ? "Review spot" : "Browse spots",
                              systemImage: received?.kind == .place ? "checkmark.bubble" : "arrow.up.forward.app")
                            .font(Tokens.Typography.captionBold)
                            .frame(maxWidth: .infinity, minHeight: Tokens.Layout.minTapTarget)
                    }
                    .buttonStyle(.tweenPrimary(.subtle))

                    Button(action: onImOut) {
                        Label("I'm out", systemImage: "location.slash")
                            .font(Tokens.Typography.captionBold)
                            .frame(maxWidth: .infinity, minHeight: Tokens.Layout.minTapTarget)
                    }
                    .buttonStyle(.tweenPrimary(.destructive))
                    .disabled(isSending)
                    .accessibilityHint("Stops sharing you as active for this meetup")
                }
            }
        }
    }

    private var compactAppIcon: some View {
        ZStack {
            Circle()
                .fill(Tokens.Palette.brandLight)
            Image(systemName: "point.topleft.down.curvedto.point.bottomright.up")
                .font(Tokens.Typography.headline)
                .foregroundStyle(Tokens.Palette.accent)
        }
        .frame(width: 42, height: 42)
    }

    private var rosterCountPill: some View {
        let count = currentParticipantCount ?? (isUserIn ? 1 : 0)
        return rosterPill("\(count) in", systemImage: "person.2.fill", color: isUserIn ? Tokens.Palette.success : Tokens.Palette.textSecondary)
    }

    /// Overlapping avatar dots for who's in (redesign: the roster strip, at
    /// compact scale) — falls back to a plain count when no roster is on the
    /// bubble yet. Names are sanitised so an unnamed sender reads as a glyph.
    @ViewBuilder
    private var compactRoster: some View {
        let participants = received?.participants ?? []
        let rosterCount = currentParticipantCount ?? participants.count
        if participants.count > 1 {
            HStack(spacing: -8) {
                ForEach(Array(participants.prefix(3).enumerated()), id: \.offset) { _, p in
                    Text(UserName.peerDisplayName(p.name) == "Friend" ? "•" : SpotETADisplay.initials(for: p.name))
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(Tokens.Palette.onBrand)
                        .frame(width: 24, height: 24)
                        .background(Tokens.Palette.brand, in: Circle())
                        .overlay(Circle().strokeBorder(Tokens.Palette.surfaceSecondary, lineWidth: 1.5))
                }
                if participants.count > 3 {
                    Text("+\(participants.count - 3)")
                        .font(Tokens.Typography.caption2Bold)
                        .foregroundStyle(Tokens.Palette.textSecondary)
                        .padding(.horizontal, Tokens.Spacing.s2)
                        .frame(height: 24)
                        .background(Tokens.Palette.surface, in: Capsule())
                        .padding(.leading, 12)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(rosterCount) people in")
        } else if rosterCount > 1 {
            rosterPill("\(rosterCount) in", systemImage: "person.2.fill", color: Tokens.Palette.accent)
        }
    }

    private func rosterPill(_ title: String, systemImage: String, color: Color) -> some View {
        Label(title, systemImage: systemImage)
            .font(Tokens.Typography.captionBold)
            .foregroundStyle(color)
            .lineLimit(1)
            .padding(.horizontal, Tokens.Spacing.s2)
            .frame(minHeight: 30)
            .background(color.opacity(0.12), in: Capsule())
    }

    /// The compact CTA. Nothing renders when the user is already in — the
    /// header/status pill carries that state, and the confirmation banner it
    /// used to show pushed the layout past the keyboard-height budget.
    @ViewBuilder
    private var compactPrimaryAction: some View {
        if isUserIn {
            // Nothing: the header/status pill already says "You're in", and any
            // delivery status (staged "tap send to deliver" hint, failures)
            // renders via the card subtitle / launcher status line. A banner
            // here pushed the stack past the keyboard-height budget.
            EmptyView()
        } else if isSending {
            HStack(spacing: Tokens.Spacing.s2) {
                ProgressView()
                Text(statusMessage ?? "Sharing...")
                    .font(Tokens.Typography.headline)
            }
            .frame(maxWidth: .infinity, minHeight: Tokens.Layout.primaryControlHeight)
            .background(Tokens.Palette.neutralAction, in: Capsule())
        } else {
            Button(action: onImIn) {
                Label("I'm in", systemImage: "location.fill")
                    .font(Tokens.Typography.headline)
                    .frame(maxWidth: .infinity, minHeight: Tokens.Layout.primaryControlHeight)
            }
            .buttonStyle(.tweenPrimary())
            .accessibilityHint("Shares where you are with your friend")
        }
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let received {
            TweenMapSnapshotView(
                markers: markers(for: received),
                cornerRadius: Tokens.Radius.card,
                focusCoordinate: received.kind == .place ? received.coordinate : nil)
                .frame(width: 96, height: 72)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: Tokens.Radius.card).fill(Tokens.Palette.surfaceSecondary)
                Image(systemName: "map.fill").foregroundStyle(Tokens.Palette.textTertiary)
            }
            .frame(width: 96, height: 72)
        }
    }

    private var statusPill: some View {
        HStack(spacing: Tokens.Spacing.s1) {
            Image(systemName: isUserIn ? "checkmark.circle.fill" : "location.circle")
            Text(isUserIn ? "You are in" : "Waiting on you")
        }
        .font(Tokens.Typography.captionBold)
        .foregroundStyle(isUserIn ? Tokens.Palette.success : Tokens.Palette.accent)
        .padding(.horizontal, Tokens.Spacing.s2)
        .frame(minHeight: 26)
        .background((isUserIn ? Tokens.Palette.success : Tokens.Palette.brand).opacity(0.12), in: Capsule())
    }

    /// The received payload plus fresh participant cache when available. In a
    /// group chat the bubble carries everyone who's "in" via
    /// `state.participants`; render a friend pin for each. Self is rendered
    /// separately from the local cache, deduped by participant identity so I don't double-pin
    /// when I'm in the received roster.
    private func markers(for state: TweenState) -> [MapMarker] {
        var result: [MapMarker] = []
        let myName = UserProfile.displayName ?? UserName.fallback
        let myId = localParticipantID ?? myName

        if state.kind == .place {
            // The place itself.
            result.append(MapMarker(coordinate: state.coordinate, role: .fairSpot))
        }

        // Every "in" participant other than me from the group roster.
        for participant in state.participants where !participant.matches(id: myId, name: myName) {
            result.append(MapMarker(coordinate: participant.coordinate, role: .friend))
        }
        // For legacy bubbles (kind=.participant, empty participants[]) the
        // main coord IS the friend's pin. representsParticipantLocation rules
        // out `.leave` payloads, whose main coord is the LEAVER's last position
        // — an empty-roster leave must not pin the person who just left.
        if state.representsParticipantLocation && state.participants.isEmpty {
            result.append(MapMarker(coordinate: state.coordinate, role: .friend))
        }

        if let me = LocationCache.loadSelf()?.coordinate {
            result.append(MapMarker(coordinate: me, role: isUserIn ? .selfActive : .selfDot))
        }
        return result
    }

    private var title: String {
        if received?.kind == .place, let received {
            return received.text
        }
        if let name = received?.senderName, !name.isEmpty {
            return "\(name) invited you to meet up"
        }
        if let received { return received.text }
        return isUserIn ? "You're in" : "Find a place to meet"
    }

    private var subtitle: String {
        if let statusMessage {
            return statusMessage
        }
        if received?.messageType == .leave {
            return isUserIn ? "They stepped out — you're still in" : "They stepped out"
        }
        if received?.kind == .place, received?.isFullyAgreed == true {
            return isUserIn ? "It's a plan — tap for directions" : "It's a plan — tap “I'm in” to rejoin"
        }
        if received?.kind == .place {
            return isUserIn ? "Review maps and agreement" : "Tap “I'm in” to share"
        }
        if received?.senderName != nil {
            return "Tap to find a fair spot"
        }
        if received != nil {
            return isUserIn ? "Tap to pick a fair spot" : "Your friend shared a spot — tap to join"
        }
        return isUserIn ? "Waiting for your friend…" : "Tap “I'm in” to share where you are"
    }

}

#Preview("Compact") {
    CompactView(
        received: TweenState(text: "Blue Bottle Coffee", latitude: 37.7765, longitude: -122.4255),
        isUserIn: false,
        onImIn: {},
        onExpand: {}
    )
    .frame(height: 120)
}
