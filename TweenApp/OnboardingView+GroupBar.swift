import SwiftUI
import MapKit

// The map's group status bar: who's in, how far each of them is from the spot
// in focus, and how they're travelling. Split out of OnboardingView so the
// derivation can be a pure static function — the view layer is where this
// codebase's defects live, and `groupMembers(...)` is the part worth testing.
extension OnboardingView {

    /// Builds the bar's rows from the ranking roster and whichever spot is in
    /// focus.
    ///
    /// PURE on purpose. The equivalent logic inlined in a `var` inside the view
    /// would be unreachable from tests, which is exactly how the travel-mode
    /// bug shipped: the ranker honoured walking while every surface drew a car.
    ///
    /// `focused` is the ranked spot the user is looking at — the selected pin
    /// if there is one, otherwise the best result. Nil means no ranking yet, and
    /// members come back with `eta == nil` rather than an invented number.
    static func groupMembers(
        participants: [Participant],
        focused: RankedSpot?,
        plan: MeetupPlan,
        localID: String,
        localName: String
    ) -> [GroupMemberStatus] {
        let labels = shortLabels(for: participants.map(\.name))
        return participants.enumerated().map { index, participant in
            let isLocal = participant.matches(
                LocalParticipantContext(id: localID, name: localName))
            // Match the ETA by id, then fall back to name for legacy rosters
            // whose payloads carry `id == name` (TweenState.decodeParticipants).
            let eta = focused?.etas.first { $0.id == participant.id }
                ?? focused?.etas.first { $0.name == participant.name }
            return GroupMemberStatus(
                id: participant.id,
                label: isLocal ? "You" : labels[index],
                eta: eta?.eta,
                fromRoute: eta?.fromRoute ?? false,
                modeUnavailable: eta?.modeUnavailable ?? false,
                mode: plan.mode(for: participant.id),
                needsRide: participant.needsRide,
                isLocal: isLocal)
        }
    }

    /// First names only, with just enough added to tell two people apart.
    ///
    /// The panel is a glance surface a few characters wide — "Belal Elmeswari"
    /// and "Kavi's place" push it across the map and bury the time, which is the
    /// thing you're actually looking at. So: first name, and only when two
    /// people share one does the second get an initial ("Hamza R.", "Hamza E.").
    /// Identical first name AND initial falls back to the full name, because a
    /// label that can't distinguish two people is worse than a long one.
    ///
    /// Pure and positional — the caller maps it back over the roster in order.
    static func shortLabels(for names: [String]) -> [String] {
        let firsts = names.map(firstName)
        var counts: [String: Int] = [:]
        for first in firsts { counts[first.lowercased(), default: 0] += 1 }

        var labelled: [String] = []
        for (index, first) in firsts.enumerated() {
            guard counts[first.lowercased(), default: 0] > 1 else {
                labelled.append(first); continue
            }
            if let initial = surnameInitial(names[index]) {
                labelled.append("\(first) \(initial).")
            } else {
                labelled.append(UserName.peerDisplayName(names[index]))
            }
        }
        // Two people who are STILL identical (same first name, same initial)
        // get their full names back rather than two rows that read the same.
        var finalCounts: [String: Int] = [:]
        for label in labelled { finalCounts[label.lowercased(), default: 0] += 1 }
        return labelled.enumerated().map { index, label in
            finalCounts[label.lowercased(), default: 0] > 1
                ? UserName.peerDisplayName(names[index])
                : label
        }
    }

    /// The first whitespace-separated token, with a possessive stripped so a
    /// manual point called "Kavi's place" reads as "Kavi" rather than "Kavi's".
    static func firstName(_ raw: String) -> String {
        let sanitised = UserName.peerDisplayName(raw)
        guard let token = sanitised.split(separator: " ").first else { return sanitised }
        var first = String(token)
        for suffix in ["'s", "\u{2019}s"] where first.lowercased().hasSuffix(suffix) {
            first = String(first.dropLast(suffix.count))
        }
        return first.isEmpty ? sanitised : first
    }

    /// First letter of the SECOND token, when there is one.
    static func surnameInitial(_ raw: String) -> String? {
        let parts = UserName.peerDisplayName(raw).split(separator: " ")
        guard parts.count > 1, let letter = parts[1].first else { return nil }
        return String(letter).uppercased()
    }

    /// The rows currently on screen.
    var groupBarMembers: [GroupMemberStatus] {
        guard let participants = searchRankingParticipants else { return [] }
        return Self.groupMembers(
            participants: participants,
            focused: focusedRankedSpot,
            plan: MeetupPlanStore.current,
            localID: TweenIdentity.stableID,
            localName: UserProfile.displayName ?? UserName.fallback)
    }

    /// The spot whose times the bar is reporting: what the user has selected,
    /// else the best-ranked result. Without this the bar would go blank the
    /// moment a pin was deselected, which reads as broken rather than idle.
    var focusedRankedSpot: RankedSpot? {
        if let selectedResult, let match = rankedMatch(for: selectedResult) { return match }
        return rankedSpots.first
    }

    /// Advances one person to the next travel mode and re-ranks.
    ///
    /// Cycles rather than opening a picker: three options is short enough that
    /// tapping through them is faster than any menu, and it keeps the whole
    /// interaction on the map instead of behind the Plan sheet — the thing that
    /// made modes feel buried ("I have to hit plan then switch so it's weird").
    func cycleTravelMode(for member: GroupMemberStatus) {
        guard ProEntitlement.isUnlocked else {
            activeSheet = .friends
            friendsSubSheet = .paywall
            return
        }
        var plan = MeetupPlanStore.current
        let next = Self.nextMode(after: plan.mode(for: member.id))
        plan.setMode(next, for: member.id)
        MeetupPlanStore.save(plan)

        let who = member.isLocal ? "You're" : "\(member.label) is"
        showToast("\(who) \(Self.modePhrase(next))")
        rerankAfterPlanChange()
    }

    /// Sets a specific person's mode outright, from the bar's hold menu.
    func setTravelMode(_ mode: TravelMode, for member: GroupMemberStatus) {
        guard ProEntitlement.isUnlocked else {
            activeSheet = .friends
            friendsSubSheet = .paywall
            return
        }
        var plan = MeetupPlanStore.current
        plan.setMode(mode, for: member.id)
        MeetupPlanStore.save(plan)
        let who = member.isLocal ? "You're" : "\(member.label) is"
        showToast("\(who) \(Self.modePhrase(mode))")
        rerankAfterPlanChange()
    }

    /// Sets the LOCAL user's mode outright (hold-to-change), as opposed to
    /// `cycleTravelMode`'s step-through. Shares the Pro gate, the toast and the
    /// re-rank so the two entry points can't drift.
    func setLocalTravelMode(_ mode: TravelMode) {
        guard ProEntitlement.isUnlocked else {
            activeSheet = .friends
            friendsSubSheet = .paywall
            return
        }
        var plan = MeetupPlanStore.current
        plan.setMode(mode, for: TweenIdentity.stableID)
        MeetupPlanStore.save(plan)
        showToast("You're \(Self.modePhrase(mode))")
        rerankAfterPlanChange()
    }

    /// Reads as a sentence. `TravelMode.title` is a noun for a picker row
    /// ("Transit"), which makes "You're transit" out of a toast.
    static func modePhrase(_ mode: TravelMode) -> String {
        switch mode {
        case .driving: return "driving"
        case .transit: return "taking transit"
        case .walking: return "walking"
        }
    }

    /// driving → transit → walking → driving.
    static func nextMode(after mode: TravelMode) -> TravelMode {
        switch mode {
        case .driving: return .transit
        case .transit: return .walking
        case .walking: return .driving
        }
    }
}
