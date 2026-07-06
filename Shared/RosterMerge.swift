import Foundation

/// Group-session roster semantics: the conversation is a standing meetup —
/// a "meeting ID" people join and leave freely, Game-Pigeon style.
///
/// An inbound bubble is ONE SENDER'S VIEW of the roster, not the roster
/// itself. Adopting it verbatim let any single message erase participants the
/// sender simply hadn't seen yet (the leave→rejoin bubble carried `[me]` and
/// wiped the whole group on every device). So instead:
///
///   - **Joins and updates merge additively.** Entries in the incoming list
///     replace their local counterpart (the sender has fresher data for the
///     people it knows about) and new entries append. A participant missing
///     from the incoming list is NOT removed — absence is ignorance, not
///     departure.
///   - **Removal is only ever an explicit act**: a `.leave` bubble removes its
///     *sender*, and nobody else.
///   - **Departure tombstones** (kept device-locally, never in URLs) filter
///     departed participants out of later rosters broadcast by peers who never
///     processed the leave. The single exception: a non-leave message FROM a
///     departed participant is their explicit rejoin and lifts their tombstone.
enum RosterMerge {

    /// How many departure keys one payload gossips. Keys are stable install
    /// IDs (36-char UUIDs), so 8 costs ~300 URL chars against the 5000
    /// budget — and any group that churns through more than 8 departures is
    /// covered by each device's local tombstones plus later payloads.
    static let gossipCap = 8

    /// The departure keys a new outgoing payload should gossip: every
    /// tombstone this device holds, minus anyone back on the outgoing roster
    /// (a rejoin outranks stale gossip), capped for the URL budget.
    static func gossipKeys(departed: Set<String>, roster: [Participant]) -> [String] {
        Array(
            departed
                .filter { key in
                    !roster.contains { $0.id == key || ($0.id == $0.name && $0.name == key) }
                }
                .sorted()
                .prefix(gossipCap))
    }

    /// Identity keys for a message sender, used for tombstones and leave
    /// removal. The stable install ID when the payload carries one; the
    /// display name only for legacy payloads without a senderID (name keys
    /// can collide across people, so they are never minted alongside an ID).
    static func senderKeys(senderID: String?, senderName: String?) -> [String] {
        if let senderID, !senderID.isEmpty { return [senderID] }
        if let senderName, !senderName.isEmpty { return [senderName] }
        return []
    }

    private static func isDeparted(_ participant: Participant, departed: Set<String>) -> Bool {
        departed.contains(participant.id)
            // Legacy entries carry their name as their id; a name-keyed
            // tombstone (legacy leave) must catch those too.
            || (participant.id == participant.name && departed.contains(participant.name))
    }

    private static func sameParticipant(_ a: Participant, _ b: Participant) -> Bool {
        a.matches(id: b.id, name: b.name) || b.matches(id: a.id, name: a.name)
    }

    /// Merges one sender's roster view into the locally known roster.
    ///
    /// - Parameters:
    ///   - local: the roster this device currently believes in.
    ///   - incoming: the roster carried by the inbound payload.
    ///   - messageType: the payload's type; `.leave` removes the sender.
    ///   - senderKeys: identity keys of the payload's sender (`senderKeys(senderID:senderName:)`).
    ///   - departed: identity keys of participants known to have left this
    ///     conversation. The sender is exempt on non-leave messages (rejoin).
    static func merge(local: [Participant],
                      incoming: [Participant],
                      messageType: TweenState.MessageType,
                      senderKeys: [String],
                      departed: Set<String>) -> [Participant] {
        let senderKeySet = Set(senderKeys)
        // On a non-leave message the sender is announcing presence — their
        // own tombstone (if any) does not apply to this payload.
        let effectiveDeparted = messageType == .leave
            ? departed.union(senderKeySet)
            : departed.subtracting(senderKeySet)

        var merged = local
        for entry in incoming where !isDeparted(entry, departed: effectiveDeparted) {
            if let index = merged.firstIndex(where: { sameParticipant($0, entry) }) {
                merged[index] = entry
            } else {
                merged.append(entry)
            }
        }
        merged.removeAll { isDeparted($0, departed: effectiveDeparted) }
        return merged
    }
}
