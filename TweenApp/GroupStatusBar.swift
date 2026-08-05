import SwiftUI
import MapKit

/// One person's line in the group bar.
struct GroupMemberStatus: Identifiable, Equatable {
    let id: String
    /// "You" for the local user, the peer's display name otherwise.
    let label: String
    /// Seconds to the focused spot, or nil when nothing is focused yet.
    let eta: TimeInterval?
    /// True when the ETA came from a real route rather than a straight-line
    /// guess — a guessed number carries a `~`.
    let fromRoute: Bool
    /// True when the planned mode had no answer and this number is DRIVING.
    /// Never dress a driving number as transit (2026-08-04).
    let modeUnavailable: Bool
    let mode: TravelMode
    let needsRide: Bool
    let isLocal: Bool
}

/// A glance-able roster over the map: who's in, how long each of them is from
/// the spot in focus, and how they're getting there.
///
/// Sits top-leading, where Maps puts its weather widget — the one corner of the
/// map that stays free, and it reads as ambient rather than chrome.
///
/// ONE stacked panel, not a rail of chips. The first build laid people out
/// horizontally with the name above the time, which ran off the screen at three
/// people and ate the top of the map ("way too much space"). Stacked rows share
/// a single material, so a fourth person costs ~18pt of height instead of
/// ~110pt of width, and the panel stays narrow enough to leave the map readable.
///
/// Exists because travel mode was invisible AND unreachable: the ranker has
/// honoured per-person driving/transit/walking since Pro shipped, but the only
/// way to see or change it was to open a spot, hit Plan, and read a picker —
/// while every result row drew a car icon regardless of the actual mode. The
/// app could rank you on foot and tell you that you were driving (device
/// report 2026-08-05: "it's saying I'm an hour away from stuff right next to
/// me").
struct GroupStatusBar: View {
    let members: [GroupMemberStatus]
    /// Cycles that person's mode. Applies to anyone: in a real group you often
    /// know your friend is getting the train, and there is no channel to ask
    /// them — the modes are local planning data either way.
    var onCycleMode: (GroupMemberStatus) -> Void
    /// Sets a specific mode for a specific person, from the hold-to-change
    /// menu. Tapping cycles (fast when you just want the next one); holding
    /// names all three, which matches the directions tile on the place card so
    /// the gesture means the same thing in both places.
    var onSetMode: (GroupMemberStatus, TravelMode) -> Void = { _, _ in }

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var surface: AnyShapeStyle {
        reduceTransparency ? AnyShapeStyle(Tokens.Palette.surface)
                           : AnyShapeStyle(.regularMaterial)
    }

    var body: some View {
        if !members.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(members.enumerated()), id: \.element.id) { index, member in
                    if index > 0 {
                        // Inset hairline, Maps-style — a full-width rule in a
                        // panel this small reads as a table.
                        Rectangle()
                            .fill(Tokens.Palette.textPrimary.opacity(0.12))
                            .frame(height: 0.5)
                            .padding(.leading, 22)
                    }
                    row(member)
                }
            }
            .padding(.vertical, 2)
            .background(surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    private func row(_ member: GroupMemberStatus) -> some View {
        Button {
            onCycleMode(member)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: member.needsRide ? "figure.wave" : member.mode.systemImage)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(member.needsRide ? Tokens.Palette.warning
                                                      : Tokens.Palette.accent)
                    .frame(width: 13)

                Text(member.label)
                    .font(.system(size: 12))
                    .foregroundStyle(Tokens.Palette.textSecondary)
                    .lineLimit(1)

                Text(timeText(member))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(member.isLocal ? Tokens.Palette.accent
                                                    : Tokens.Palette.textPrimary)
                    .lineLimit(1)
                    .monospacedDigit()
            }
            .padding(.horizontal, 9)
            // 7, not 4. At 4 the row was ~23pt — half Apple's 44pt minimum,
            // with a second row directly beneath it, so a near-miss silently
            // changed the WRONG person's mode and re-ranked everything. The
            // extra 3pt a side costs ~6pt of panel height in total and buys
            // back the accuracy.
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(GroupChipButtonStyle())
        .contextMenu {
            Picker("How they're getting there", selection: Binding(
                get: { member.mode },
                set: { onSetMode(member, $0) }
            )) {
                ForEach(TravelMode.allCases) { mode in
                    Label(mode.title, systemImage: mode.systemImage).tag(mode)
                }
            }
        }
        .accessibilityLabel(accessibilityLabel(member))
        .accessibilityHint("Changes how \(member.isLocal ? "you get" : "\(member.label) gets") there. Touch and hold to pick a mode.")
    }

    /// "—" when nothing is focused: the panel still shows who's in and lets
    /// modes be set before a spot exists. A fabricated time would be worse.
    private func timeText(_ member: GroupMemberStatus) -> String {
        guard let eta = member.eta else { return "—" }
        let formatted = formatETA(eta)
        return member.fromRoute ? formatted : "~\(formatted)"
    }

    private func accessibilityLabel(_ member: GroupMemberStatus) -> String {
        var parts = [member.label]
        if let eta = member.eta {
            parts.append(member.fromRoute
                         ? formatETA(eta)
                         : "about \(formatETA(eta))")
        } else {
            parts.append("no travel time yet")
        }
        // The caveat has to ride on the number wherever the number goes —
        // silently showing a driving time under a tram icon is the bug this
        // whole panel exists to stop.
        parts.append(member.modeUnavailable
                     ? "\(member.mode.title) unavailable, driving time shown"
                     : member.mode.title)
        if member.needsRide { parts.append("needs a ride") }
        return parts.joined(separator: ", ")
    }
}

/// Press feedback on touch-DOWN, not on release — a row that only reacts when
/// you lift reads as dead (Designing Fluid Interfaces). Reuses the shared
/// `tweenPressFeedback` so it behaves like every other Tween control.
private struct GroupChipButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .tweenPressFeedback(isPressed: configuration.isPressed)
    }
}
