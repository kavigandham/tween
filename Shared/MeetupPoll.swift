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
    /// Generation counter for the DECISION SLOT ONLY, bumped every time the
    /// decision is set or cleared.
    ///
    /// Needed because "no decision" has two meanings on the wire — "never had
    /// one" and "somebody reopened it" — and the merge can't tell them apart
    /// from a nil. Without it, a `.pick` that reopened a settled meetup left
    /// every OTHER device rendering the old plan with no vote board at all,
    /// and their only exits were "I'm out" or locking in the stale place
    /// (audit 2026-09-19). Higher generation wins.
    var decisionSeq: Int = 0

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
        // A new place on the board reopens the question — and says so, loudly
        // enough to survive the trip to another device.
        if decidedOptionID != nil {
            decidedOptionID = nil
            decisionSeq += 1
        }
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

    /// Reopens the question without putting anything new on the board — the
    /// local half of a `.pick` whose board was dropped by the size ladder.
    /// The generation counter travels WITH the board (it has to; see
    /// TweenState.encodedURL), so a degraded pick can't say "I reopened this"
    /// on the wire and the receiver has to infer it from the message type.
    mutating func reopen() {
        guard decidedOptionID != nil else { return }
        decidedOptionID = nil
        decisionSeq += 1
    }

    mutating func lockIn(_ optionID: String) {
        guard options.contains(where: { $0.id == optionID }) else { return }
        guard decidedOptionID != optionID else { return }
        decidedOptionID = optionID
        decisionSeq += 1
    }

    /// Every string a participant can be addressed by, for matching a board's
    /// `proposerID` and vote keys.
    ///
    /// A participant's display NAME is minted only when it is already serving
    /// as their id (`id == name`) — exactly the rule `RosterMerge.isDeparted`
    /// applies, and for the same reason its doc gives: "name keys can collide
    /// across people, so they are never minted alongside an ID." Minting names
    /// unconditionally let a DEPARTED member's name-keyed option survive
    /// whenever any live member happened to share that name, which is the very
    /// thing `normalized` exists to prevent.
    ///
    /// Empty strings are excluded on both sides. An unnamed participant
    /// decodes with `id == name == ""` (`decodeParticipants` collapses id to
    /// name and `outgoingName` blanks the "You" fallback), and an option whose
    /// proposer failed to resolve carries `""` too — so admitting it would make
    /// one unnamed participant vouch for every unattributable option and vote.
    static func identityKeys(of participants: [Participant]) -> Set<String> {
        var keys = Set<String>()
        for participant in participants where !participant.id.isEmpty {
            keys.insert(participant.id)
            if participant.id == participant.name {
                keys.insert(participant.name)
            }
        }
        return keys
    }

    /// Scopes the poll to who is actually still in: a person who left takes
    /// their pick and their vote with them. Without this a leaver's option
    /// could still win a vote they are not attending.
    func normalized(participants: [Participant],
                    departed: Set<String> = []) -> MeetupPoll {
        guard !participants.isEmpty else { return self }
        let live = Self.identityKeys(of: participants)
        // NOT ONE proposer resolves, and none of them is a KNOWN DEPARTURE?
        // Then this roster and this board are naming people in different
        // keyspaces (stable ids vs display names) rather than telling us
        // everyone left, and normalizing against a roster that can't name
        // anybody on the board is meaningless. The concrete path: the host app
        // writes the board keyed by `TweenIdentity.stableID`, the extension
        // restores `currentParticipants` from a snapshot whose entries came
        // from a payload that lost its ids, and the wipe was then persisted by
        // `mergePoll`'s `savePoll` — so a settled meetup deleted itself
        // permanently (device report 2026-09-20).
        //
        // The tombstone check is what keeps this from becoming the opposite
        // bug. Without it, the ordinary 3-person case — one person proposes
        // the only place, the group locks it in, the proposer leaves — read as
        // a keyspace mismatch, so the departed proposer's option AND the
        // decision survived. The remaining two were pinned to MEETUP SET at a
        // place its chooser had walked away from, with no board and no "I'm
        // out" in that branch to escape it, and a later `.leave` re-entered
        // the same bail-out (post-push audit 2026-09-21).
        //
        // Rosters of 1 skip the bail-out entirely: that is the everyday "my
        // friend left" shape, where the pick must go with them even if this
        // device never recorded a tombstone.
        if participants.count >= 2, !options.isEmpty,
           !options.contains(where: { live.contains($0.proposerID) }),
           !options.contains(where: { departed.contains($0.proposerID) }) {
            return self
        }
        var copy = self
        copy.options = options.filter { live.contains($0.proposerID) }
        let liveOptionIDs = Set(copy.options.map(\.id))
        copy.votes = votes.filter { live.contains($0.key) && liveOptionIDs.contains($0.value) }
        if let decided = copy.decidedOptionID, !liveOptionIDs.contains(decided) {
            copy.decidedOptionID = nil
            copy.decisionSeq += 1
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
    /// `preservingVoteOf` is the LOCAL participant, and it is ONLY correct
    /// when `incoming` arrived from a PEER. A peer's snapshot may predate this
    /// device's own vote, and overwriting it let a stale bubble move your vote
    /// to a place you didn't choose — and, in a three-person chat, settle the
    /// meetup on it.
    ///
    /// Pass nil when `incoming` is a board THIS device just composed: there the
    /// incoming copy is the fresh one, and preserving `local` reverts the very
    /// vote the user just cast (and re-broadcasts the old one on the next
    /// send). `MessagesViewController.mergePoll(_:from:)` names the two cases
    /// so a call site can't get the direction wrong by omission.
    static func merged(local: MeetupPoll, incoming: MeetupPoll,
                       preservingVoteOf localID: String? = nil) -> MeetupPoll {
        var result = local
        let myVote = localID.flatMap { local.votes[$0] }
        // MY OWN pick is mine to know. The re-pick rule below ("same proposer,
        // different place = they changed their mind, drop the old one") is only
        // valid when `incoming` is the newer statement — and for the local
        // user it never is: a peer's board can predate my re-pick, in which
        // case applying the rule deletes the place I just moved to and
        // resurrects the one I walked away from. Combined with the vote
        // fallback below that re-cast my old vote and could auto-settle the
        // meetup there (audit 2026-09-19, third pass).
        //
        // Still adopted when this device holds no pick of mine — after a cold
        // launch a peer's board is the only way to relearn it.
        let iHoldMyOwnPick = localID.flatMap { local.option(proposedBy: $0) } != nil
        let incomingOptions = incoming.options.filter { option in
            !(iHoldMyOwnPick && option.proposerID == localID)
        }
        // Re-picks first: a proposer whose incoming option differs from the
        // one we hold has changed their mind, and their old option must go
        // before the union below would keep both.
        for option in incomingOptions {
            if let existing = result.option(proposedBy: option.proposerID), existing.id != option.id {
                result.options.removeAll { $0.id == existing.id }
                result.votes = result.votes.filter { $0.value != existing.id }
            }
        }
        for option in incomingOptions where !result.options.contains(where: { $0.id == option.id }) {
            result.options.append(option)
        }
        for (voter, optionID) in incoming.votes where voter != localID {  // see preservingVoteOf
            result.votes[voter] = optionID
        }
        // Re-assert my own vote — or fall back to theirs when the place I
        // voted for is gone (a re-pick removes it). The fallback used to hang
        // off the same `if let myVote`, which made it unreachable in exactly
        // that case: the board kept my new pick with NOBODY voting for it,
        // breaking `pick`'s own invariant (audit 2026-09-19).
        if let localID {
            if let myVote, result.options.contains(where: { $0.id == myVote }) {
                result.votes[localID] = myVote
            } else if let theirs = incoming.votes[localID],
                      result.options.contains(where: { $0.id == theirs }) {
                result.votes[localID] = theirs
            }
        }
        result.votes = result.votes.filter { entry in
            result.options.contains { $0.id == entry.value }
        }
        // The decision slot goes to the newer GENERATION, so a reopen (which
        // carries no `dec` but a higher `decisionSeq`) beats a stale lock-in
        // instead of being read as silence. Equal generations from divergent
        // histories settle deterministically — a decision beats none, and two
        // different decisions break toward the lower id so every device lands
        // on the same answer without agreeing on merge order.
        if incoming.decisionSeq > result.decisionSeq {
            result.decidedOptionID = incoming.decidedOptionID
            result.decisionSeq = incoming.decisionSeq
        } else if incoming.decisionSeq == result.decisionSeq,
                  let theirs = incoming.decidedOptionID {
            if let ours = result.decidedOptionID {
                result.decidedOptionID = min(ours, theirs)
            } else {
                result.decidedOptionID = theirs
            }
        }
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

    /// The options that can actually travel alongside `participants`, in wire
    /// order — proposer resolvable, no duplicate ids.
    ///
    /// EVERY encoded field must index THIS list: `opts`, `votes` and `dec`
    /// alike. They used to disagree — `encodeOptions` dropped options whose
    /// proposer wasn't on the roster while votes and the decision were indexed
    /// against the unfiltered array — so one dropped option shifted every later
    /// index by one and the receiver either lost a vote or, worse, assigned it
    /// to a different place and moved the decision onto somewhere nobody chose
    /// (audit 2026-09-19).
    func encodableOptions(participants: [Participant]) -> [PollOption] {
        let live = Set(participants.map(\.id))
        var seen = Set<String>()
        return options.filter { option in
            guard live.contains(option.proposerID) else { return false }
            return seen.insert(option.id).inserted
        }
    }

    /// `name:lat:lon:proposerIndex` records, comma separated. Pass the list
    /// from `encodableOptions(participants:)`.
    static func encodeOptions(_ options: [PollOption], participants: [Participant]) -> String {
        // NOT `uniqueKeysWithValues`: that is a runtime TRAP on a duplicate
        // key, and participant ids genuinely collide — `decodeParticipants`
        // uses the name as the id, and `outgoingName` blanks the "You"
        // fallback, so two unnamed people decode to two entries with id "".
        // A crafted link could therefore crash both processes the moment the
        // decoded state was re-encoded to be stored (audit 2026-09-19).
        let index = Dictionary(participants.enumerated().map { ($0.element.id, $0.offset) },
                               uniquingKeysWith: { first, _ in first })
        return options.compactMap { option -> String? in
            guard let proposerIndex = index[option.proposerID] else { return nil }
            let name = TweenState.encodeNames([option.name])
            return "\(name):\(coordinate(option.latitude)):\(coordinate(option.longitude)):\(proposerIndex)"
        }.joined(separator: ",")
    }

    /// Decoded options as SLOTS — one entry per record on the wire, nil where
    /// a record was rejected.
    ///
    /// Positional fidelity is the whole point: `votes` and `dec` are indexes
    /// into the list the SENDER encoded, so silently compacting rejected
    /// records here shifts every later vote by one — a vote or a decision
    /// landing on a place nobody chose. That's the same defect the encode side
    /// had, on the other side of the wire, and the dedupe below made it easier
    /// to trigger (audit 2026-09-19). Callers index the slots, then compact.
    static func decodeOptionSlots(_ raw: String, participants: [Participant]) -> [PollOption?] {
        var seen = Set<String>()
        return raw.split(separator: ",", omittingEmptySubsequences: false).map { entry -> PollOption? in
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
            let option = PollOption(name: name, latitude: lat, longitude: lon,
                                    proposerID: participants[proposerIndex].id)
            // Dedupe on the way IN, so a payload carrying the same place twice
            // can't produce a board that traps when it is re-encoded. The slot
            // stays (as nil) so the indexes don't move.
            guard seen.insert(option.id).inserted else { return nil }
            return option
        }
    }

    /// Positional over the roster: entry `i` is the option index participant
    /// `i` voted for, or "-" for "hasn't voted".
    static func encodeVotes(_ votes: [String: String],
                            options: [PollOption],
                            participants: [Participant]) -> String {
        // Duplicate-tolerant for the same reason as encodeOptions: two
        // decoded options can share a content id, and trapping here would
        // crash on re-encode.
        let optionIndex = Dictionary(options.enumerated().map { ($0.element.id, $0.offset) },
                                     uniquingKeysWith: { first, _ in first })
        return participants.map { participant -> String in
            guard let optionID = votes[participant.id],
                  let index = optionIndex[optionID] else { return "-" }
            return String(index)
        }.joined(separator: ",")
    }

    /// `slots` must be `decodeOptionSlots`' output — the sender's indexes only
    /// mean anything against the positions they encoded.
    static func decodeVotes(_ raw: String,
                            slots: [PollOption?],
                            participants: [Participant]) -> [String: String] {
        var result: [String: String] = [:]
        for (offset, token) in raw.split(separator: ",", omittingEmptySubsequences: false).enumerated() {
            guard participants.indices.contains(offset),
                  let index = Int(token),
                  slots.indices.contains(index),
                  let option = slots[index] else { continue }
            result[participants[offset].id] = option.id
        }
        return result
    }

    private static func coordinate(_ value: Double) -> String {
        String(format: "%.6f", value)
    }
}

// MARK: - Codable

/// Hand-written decode, in an EXTENSION so the memberwise init survives.
///
/// Swift's synthesized `init(from:)` emits `decode(_:forKey:)` for a
/// non-optional property and **ignores its default value** — so adding
/// `decisionSeq` to a struct that already has stored blobs made every one of
/// them throw `keyNotFound`. `MeetupSnapshot.poll` decodes through here, and
/// `ConversationMeetupStore.load` is a `try?`, so one missing key would have
/// discarded the WHOLE conversation snapshot: roster, proposal, agreement,
/// board and pending draft, for every chat written by the previous build
/// (audit 2026-09-19). Every field is tolerant of absence for the same reason.
extension MeetupPoll {
    private enum CodingKeys: String, CodingKey {
        case options, votes, decidedOptionID, decisionSeq
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        options = try c.decodeIfPresent([PollOption].self, forKey: .options) ?? []
        votes = try c.decodeIfPresent([String: String].self, forKey: .votes) ?? [:]
        decidedOptionID = try c.decodeIfPresent(String.self, forKey: .decidedOptionID)
        decisionSeq = try c.decodeIfPresent(Int.self, forKey: .decisionSeq) ?? 0
    }
}
