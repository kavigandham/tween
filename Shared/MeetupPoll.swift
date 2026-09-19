import Foundation
import CoreLocation

/// One place on the board, and who put it there.
///
/// EXACTLY ONE option per person. That rule is the whole reason the poll is
/// bounded: the roster already rides in every payload, so options can never
/// outnumber it, and "Hassan picked Hey Tea, Belal picked Kung Fu Tea" is the
/// literal mental model people already have for this argument. Picking again
/// REPLACES your own option rather than adding a third.
struct PollOption: Equatable, Identifiable, Codable {
    let name: String
    let latitude: Double
    let longitude: Double
    /// Participant id of whoever picked it.
    let proposerID: String

    init(name: String, latitude: Double, longitude: Double, proposerID: String) {
        self.name = TweenState.boundedName(name)
        self.latitude = latitude
        self.longitude = longitude
        self.proposerID = proposerID
    }

    init(name: String, coordinate: CLLocationCoordinate2D, proposerID: String) {
        self.init(name: name, latitude: coordinate.latitude,
                  longitude: coordinate.longitude, proposerID: proposerID)
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// Content identity, so the SAME cafe picked from two devices (whose
    /// MapKit results differ by float noise) is one option, not two.
    /// 1e-4° ≈ 11 m — the same epsilon `TweenState.sameSpot(as:)` uses.
    var id: String { Self.key(name: name, latitude: latitude, longitude: longitude) }

    static func key(name: String, latitude: Double, longitude: Double) -> String {
        let lat = Int((latitude * 10_000).rounded())
        let lon = Int((longitude * 10_000).rounded())
        return "\(name.lowercased())@\(lat),\(lon)"
    }
}

/// The negotiation, as a poll instead of a chain.
///
/// The old model was a linear propose → agree → counter chain: one live
/// proposal at a time, and "I'd rather go somewhere else" was expressed by
/// REPLACING the proposal, which made the two intents ("I agree" and "I don't")
/// share one slot and produced the nonsense the user hit — a disagreement that
/// resolved as an agreement to the thing being disagreed with.
///
/// Here both picks coexist and are voted on:
///   * one option per person (see `PollOption`),
///   * one vote per person,
///   * picking auto-votes for your own pick,
///   * the winner is simply the most votes.
///
/// Auto-decide is deliberately conservative — it fires only when the vote is
/// UNANIMOUS (see `settledOption` for why a plurality must not settle itself).
/// A tie — the 1–1 two-person case, which is the normal opening position —
/// stays open, broken by someone switching their vote or by any participant
/// tapping "Lock in <leader>".
///
/// Every operation is order-independent (`merged` is a union) because bubbles
/// arrive out of order and only when tapped — see `TweenState` for how this
/// rides inside `MSMessage.url`, and `normalized(participants:)` for the rule
/// that keeps a departed person's pick from winning.
struct MeetupPoll: Equatable, Codable {
    /// First-seen order. Stable across merges so the board doesn't reshuffle
    /// under someone's finger.
    var options: [PollOption] = []
    /// voter participant id → `PollOption.id`.
    var votes: [String: String] = [:]
    /// Set once the group locked one in — the terminal state.
    var decidedOptionID: String?

    static let empty = MeetupPoll()

    var isEmpty: Bool { options.isEmpty && votes.isEmpty && decidedOptionID == nil }

    // MARK: - Reading

    func option(id: String) -> PollOption? {
        options.first { $0.id == id }
    }

    func option(proposedBy participantID: String) -> PollOption? {
        options.first { $0.proposerID == participantID }
    }

    func voteCount(for optionID: String) -> Int {
        votes.values.filter { $0 == optionID }.count
    }

    func voters(for optionID: String) -> [String] {
        votes.filter { $0.value == optionID }.keys.sorted()
    }

    func vote(by participantID: String) -> String? {
        votes[participantID]
    }

    /// Options ordered the way the board shows them: most votes first, ties
    /// broken by option id so EVERY device renders the same order without
    /// having to agree on merge history.
    var standings: [(option: PollOption, votes: Int)] {
        options
            .map { ($0, voteCount(for: $0.id)) }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
                return lhs.0.id < rhs.0.id
            }
    }

    /// The single option with the most votes, or nil when it's a tie (or when
    /// nobody has voted). Nil is the signal that the group still has to talk.
    var leader: PollOption? {
        let ranked = standings
        guard let top = ranked.first, top.votes > 0 else { return nil }
        if ranked.count > 1, ranked[1].votes == top.votes { return nil }
        return top.option
    }

    /// True when two or more options are tied at the top — the 1–1 opening
    /// position of any two-person disagreement.
    var isTie: Bool {
        let ranked = standings
        guard let top = ranked.first, top.votes > 0, ranked.count > 1 else { return false }
        return ranked[1].votes == top.votes
    }

    var decidedOption: PollOption? {
        decidedOptionID.flatMap { option(id: $0) }
    }

    var isDecided: Bool { decidedOption != nil }

    func everyoneVoted(participants: [Participant]) -> Bool {
        guard !participants.isEmpty else { return false }
        return participants.allSatisfy { votes[$0.id] != nil }
    }

    func voteProgress(participants: [Participant]) -> (voted: Int, total: Int) {
        let total = max(participants.count, votes.count)
        let voted = participants.isEmpty
            ? votes.count
            : participants.filter { votes[$0.id] != nil }.count
        return (voted, total)
    }

    /// Everyone in, voting the same way. The happy path of a two-person
    /// disagreement: 1–1, one person looks at the other's pick and switches,
    /// and the meetup settles itself with nobody having to tap "confirm".
    func unanimousOption(participants: [Participant]) -> PollOption? {
        guard participants.count >= 2, everyoneVoted(participants: participants) else { return nil }
        let chosen = Set(participants.compactMap { votes[$0.id] })
        guard chosen.count == 1, let optionID = chosen.first else { return nil }
        return option(id: optionID)
    }

    /// The winner, when the group has actually settled it: an explicit
    /// lock-in, or a unanimous vote.
    ///
    /// Deliberately NOT "whoever leads once everyone has voted". Adding a
    /// place to the board IS a vote for it, so that rule would let the person
    /// putting up a brand-new contender simultaneously settle the meetup on
    /// somebody else's place — which is precisely the class of surprise this
    /// model replaced. A plurality still wins, it just wins by someone tapping
    /// "Lock in <leader>", which names what it's doing.
    func settledOption(participants: [Participant]) -> PollOption? {
        decidedOption ?? unanimousOption(participants: participants)
    }

    // MARK: - Writing

    /// Puts `option` on the board for its proposer and moves that person's
    /// vote onto it. Replaces any option they had already picked.
    ///
    /// Votes other people had cast for the REPLACED option are dropped — the
    /// place they voted for is gone, so silently carrying their vote to a
    /// place they never saw is exactly the bug this model exists to kill.
    mutating func pick(_ option: PollOption) {
        if let previous = self.option(proposedBy: option.proposerID), previous.id != option.id {
            options.removeAll { $0.id == previous.id }
            votes = votes.filter { $0.value != previous.id }
        }
        if !options.contains(where: { $0.id == option.id }) {
            options.append(option)
        }
        votes[option.proposerID] = option.id
        // A new place on the board reopens the question.
        decidedOptionID = nil
    }

    /// Puts `option` on the board WITHOUT touching votes or the decision.
    ///
    /// The repair path: a device can be looking at an option it only learned
    /// about from the bubble in front of it (a legacy `.propose` restored from
    /// a snapshot an older build wrote, say). Voting for an option the board
    /// doesn't hold is a silent no-op, so the send path inserts it first —
    /// `pick` would be wrong here, because it also re-votes and reopens a
    /// decision.
    mutating func ensure(_ option: PollOption) {
        guard !options.contains(where: { $0.id == option.id }) else { return }
        options.append(option)
    }

    /// Records one person's vote. No-op for an option that isn't on the board.
    mutating func vote(_ participantID: String, for optionID: String) {
        guard options.contains(where: { $0.id == optionID }) else { return }
        votes[participantID] = optionID
    }

    mutating func lockIn(_ optionID: String) {
        guard options.contains(where: { $0.id == optionID }) else { return }
        decidedOptionID = optionID
    }

    /// Scopes the poll to who is actually still in: a person who left takes
    /// their pick and their vote with them. Without this a leaver's option
    /// could still win a vote they are not attending.
    func normalized(participants: [Participant]) -> MeetupPoll {
        guard !participants.isEmpty else { return self }
        let live = Set(participants.map(\.id))
        var copy = self
        copy.options = options.filter { live.contains($0.proposerID) }
        let liveOptionIDs = Set(copy.options.map(\.id))
        copy.votes = votes.filter { live.contains($0.key) && liveOptionIDs.contains($0.value) }
        if let decided = copy.decidedOptionID, !liveOptionIDs.contains(decided) {
            copy.decidedOptionID = nil
        }
        return copy
    }

    /// Union merge. Bubbles arrive out of order and only when someone taps
    /// them, so this has to converge without a server and without trusting
    /// arrival order:
    ///   * options — union, local order first so the board doesn't reshuffle;
    ///     a re-pick by the same person (same proposer, new place) takes the
    ///     incoming one, since that IS the newer statement of their pick;
    ///   * votes — local, overlaid by incoming (the incoming bubble is the
    ///     sender's snapshot, which is at least as new as ours);
    ///   * decided — sticky once either side has it, because a lock-in is
    ///     terminal. A later `pick` clears it explicitly (see `pick`).
    static func merged(local: MeetupPoll, incoming: MeetupPoll) -> MeetupPoll {
        var result = local
        // Re-picks first: a proposer whose incoming option differs from the
        // one we hold has changed their mind, and their old option must go
        // before the union below would keep both.
        for option in incoming.options {
            if let existing = result.option(proposedBy: option.proposerID), existing.id != option.id {
                result.options.removeAll { $0.id == existing.id }
                result.votes = result.votes.filter { $0.value != existing.id }
            }
        }
        for option in incoming.options where !result.options.contains(where: { $0.id == option.id }) {
            result.options.append(option)
        }
        for (voter, optionID) in incoming.votes {
            result.votes[voter] = optionID
        }
        result.votes = result.votes.filter { entry in
            result.options.contains { $0.id == entry.value }
        }
        result.decidedOptionID = incoming.decidedOptionID ?? result.decidedOptionID
        if let decided = result.decidedOptionID,
           !result.options.contains(where: { $0.id == decided }) {
            result.decidedOptionID = nil
        }
        return result
    }

    // MARK: - Wire format
    //
    // Everything is INDEXED against the roster that rides in the same payload
    // (`p=` / `pids=`), never by raw id: a participant id is a 36-char UUID and
    // repeating it per option and per vote would eat the 5000-char ceiling
    // (constraint 2) for a five-person group. Encoding is therefore only
    // meaningful alongside its roster — which is exactly how every Tween
    // payload already travels.

    /// `name:lat:lon:proposerIndex` records, comma separated.
    static func encodeOptions(_ options: [PollOption], participants: [Participant]) -> String {
        let index = Dictionary(uniqueKeysWithValues:
            participants.enumerated().map { ($0.element.id, $0.offset) })
        return options.compactMap { option -> String? in
            guard let proposerIndex = index[option.proposerID] else { return nil }
            let name = TweenState.encodeNames([option.name])
            return "\(name):\(coordinate(option.latitude)):\(coordinate(option.longitude)):\(proposerIndex)"
        }.joined(separator: ",")
    }

    static func decodeOptions(_ raw: String, participants: [Participant]) -> [PollOption] {
        raw.split(separator: ",", omittingEmptySubsequences: true).compactMap { entry in
            let parts = entry.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 4,
                  let lat = Double(parts[1]),
                  let lon = Double(parts[2]),
                  TweenState.validCoordinate(lat, lon),
                  let proposerIndex = Int(parts[3]),
                  participants.indices.contains(proposerIndex)
            else { return nil }
            let raw = String(parts[0])
            let name = TweenState.boundedName(raw.removingPercentEncoding ?? raw)
            return PollOption(name: name, latitude: lat, longitude: lon,
                              proposerID: participants[proposerIndex].id)
        }
    }

    /// Positional over the roster: entry `i` is the option index participant
    /// `i` voted for, or "-" for "hasn't voted".
    static func encodeVotes(_ votes: [String: String],
                            options: [PollOption],
                            participants: [Participant]) -> String {
        let optionIndex = Dictionary(uniqueKeysWithValues:
            options.enumerated().map { ($0.element.id, $0.offset) })
        return participants.map { participant -> String in
            guard let optionID = votes[participant.id],
                  let index = optionIndex[optionID] else { return "-" }
            return String(index)
        }.joined(separator: ",")
    }

    static func decodeVotes(_ raw: String,
                            options: [PollOption],
                            participants: [Participant]) -> [String: String] {
        var result: [String: String] = [:]
        for (offset, token) in raw.split(separator: ",", omittingEmptySubsequences: false).enumerated() {
            guard participants.indices.contains(offset),
                  let index = Int(token),
                  options.indices.contains(index) else { continue }
            result[participants[offset].id] = options[index].id
        }
        return result
    }

    private static func coordinate(_ value: Double) -> String {
        String(format: "%.6f", value)
    }
}
