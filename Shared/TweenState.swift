import Foundation
import CoreLocation

/// The payload carried in an iMessage bubble's `MSMessage.url`.
///
/// Encodes a human-readable label and compact coordinates — never route geometry
/// — so the URL stays well under the 5000-char ceiling.
///
/// Group support layers a richer model on top of the original 1-on-1 format:
///   * `messageType` distinguishes invite/propose/agree/counter (replaces the
///     coarser `kind`+`action` pair, which is still emitted so older clients
///     keep parsing).
///   * `participants` carries everyone who has tapped "I'm in" so far. Each
///     received bubble is treated as the canonical roster snapshot, so the
///     latest message reconstructs the whole conversation state.
///   * `agreedIDs` lists who has agreed to the current proposal; combined
///     with the proposer (implicitly agreed) it yields full consensus. Names
///     are still emitted for display and older builds.
struct TweenState: Equatable {
    enum Kind: String {
        case participant
        case place
    }

    enum Action: String {
        case invite
        case agree
    }

    enum MessageType: String, Codable {
        case invite   // I'm joining the meetup (sharing my location)
        case leave    // I'm leaving the meetup (removing my location)
        case propose  // I'm suggesting a place
        case agree    // I'm agreeing to the proposed place
        case counter  // I'm suggesting a different place (resets agreement)
    }

    let text: String
    let latitude: Double
    let longitude: Double
    /// Display name of whoever composed this bubble, so the recipient can see
    /// who invited them. Optional so bubbles from older builds still decode.
    let senderName: String?
    /// Stable iMessage participant identity for whoever composed the bubble.
    /// New group-capable builds use this for roster replacement and agreement
    /// consensus; older bubbles fall back to `senderName`.
    let senderID: String?
    /// What the coordinate represents. Older bubbles lacked this field; those
    /// decode as `.participant` only when they are the legacy "I'm in" payload.
    let kind: Kind
    /// For a place invite, the main coordinate is the place and this optional
    /// coordinate is the sender's real location. This lets the receiver cache the
    /// sender as peer without mistaking the selected cafe for a person.
    let senderLatitude: Double?
    let senderLongitude: Double?
    /// Human intent for a place payload. The place name stays in `text`; this
    /// controls copy like "picked" vs "agreed to meet at".
    let action: Action

    /// Group-aware message classification. Derivable from `kind`/`action` for
    /// legacy bubbles; explicit for any bubble produced by group-capable code.
    let messageType: MessageType
    /// Everyone currently "in" for this meetup. Each message carries the full
    /// list so any one bubble reconstructs the whole roster.
    let participants: [Participant]
    /// Names of participants (excluding the proposer) who have agreed to the
    /// place in `text`/`coordinate`. Empty for `.invite`/`.propose`/`.counter`.
    let agreedNames: [String]
    /// Stable participant IDs that have agreed. Mirrors `agreedNames` for
    /// display/backward compatibility, but drives group consensus when present.
    let agreedIDs: [String]
    /// Monotonic per-conversation payload revision. Every bubble carries the
    /// full roster as a canonical snapshot; without ordering, tapping an OLD
    /// bubble re-adopted its stale roster verbatim (a leaver popped back
    /// "in"). Receivers ignore payloads older than the newest revision seen.
    /// Nil for payloads from older builds (and host-app sends), which keep
    /// the legacy trust-the-tap semantics.
    let revision: Int?
    /// Departure gossip: identity keys of participants known to have left.
    /// A leave bubble is only processed by whoever taps it — everyone else's
    /// roster keeps the leaver forever. Gossiping tombstones through EVERY
    /// subsequent payload lets any later tap propagate the removal, so one
    /// person processing a leave inoculates the rest of the group through
    /// their next message. Capped small (see RosterMerge.gossipCap); empty
    /// for payloads from older builds. `var` so the composers can inject the
    /// device's current tombstones at send time without rebuilding the state.
    var departed: [String]

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var senderCoordinate: CLLocationCoordinate2D? {
        guard let senderLatitude, let senderLongitude else { return nil }
        return CLLocationCoordinate2D(latitude: senderLatitude, longitude: senderLongitude)
    }

    var participantCoordinate: CLLocationCoordinate2D? {
        guard messageType != .leave else { return nil }
        return kind == .participant ? coordinate : senderCoordinate
    }

    var representsParticipantLocation: Bool {
        kind == .participant && messageType != .leave
    }

    /// True when every non-proposer participant has agreed to the current
    /// proposal. Returns false for non-proposal message types.
    var isFullyAgreed: Bool {
        guard messageType == .agree, !participants.isEmpty else { return false }
        let proposer = senderID ?? senderName ?? ""
        let useIDs = senderID != nil || !agreedIDs.isEmpty
        let needToAgree = participants.map { useIDs ? $0.id : $0.name }.filter { $0 != proposer }
        guard !needToAgree.isEmpty else { return false }
        let agreed = Set(useIDs ? agreedIDs : agreedNames)
        return needToAgree.allSatisfy { agreed.contains($0) }
    }

    func isProposer(participantID: String?, name: String) -> Bool {
        if let senderID, let participantID {
            return senderID == participantID
        }
        return senderName == name
    }

    func hasAgreed(participantID: String?, name: String) -> Bool {
        if let participantID, !agreedIDs.isEmpty {
            return agreedIDs.contains(participantID)
        }
        return agreedNames.contains(name)
    }

    func missingAgreementNames(excluding participantID: String?, name: String) -> [String] {
        participants.filter { participant in
            let isExcluded: Bool
            if let participantID {
                isExcluded = participant.id == participantID
            } else {
                isExcluded = participant.name == name
            }
            return !isProposer(participantID: participant.id, name: participant.name)
            && !hasAgreed(participantID: participant.id, name: participant.name)
            && !isExcluded
        }.map(\.name)
    }

    func encodedURL(scheme: String = "https", host: String = "tween.app") -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.path = "/m"
        // Legacy params — kept so bubbles from this build still decode in
        // older clients. New clients prefer the additions below.
        var items = [
            URLQueryItem(name: "t", value: text),
            URLQueryItem(name: "lat", value: Self.coordinateString(latitude)),
            URLQueryItem(name: "lon", value: Self.coordinateString(longitude)),
            URLQueryItem(name: "kind", value: kind.rawValue)
        ]
        if action != .invite {
            items.append(URLQueryItem(name: "action", value: action.rawValue))
        }
        if let senderName {
            items.append(URLQueryItem(name: "from", value: senderName))
        }
        if let senderID {
            items.append(URLQueryItem(name: "fromId", value: senderID))
        }
        if let senderLatitude, let senderLongitude {
            items.append(URLQueryItem(name: "slat", value: Self.coordinateString(senderLatitude)))
            items.append(URLQueryItem(name: "slon", value: Self.coordinateString(senderLongitude)))
        }
        // Group-aware params.
        items.append(URLQueryItem(name: "type", value: messageType.rawValue))
        if !participants.isEmpty {
            items.append(URLQueryItem(name: "p", value: Self.encodeParticipants(participants)))
            // Ids for the compact list, aligned by index. The compact `p=`
            // format predates ids and collapses id → name on decode; `pids=`
            // preserves identity even when `pj=` is dropped for size (below)
            // or fails to decode. Old builds ignore the extra param.
            items.append(URLQueryItem(name: "pids",
                                      value: Self.encodeNames(participants.map(\.id))))
            if let encoded = Self.encodeParticipantJSON(participants) {
                items.append(URLQueryItem(name: "pj", value: encoded))
            }
        }
        if !agreedNames.isEmpty {
            items.append(URLQueryItem(name: "agreed",
                                      value: Self.encodeNames(agreedNames)))
        }
        if !agreedIDs.isEmpty {
            items.append(URLQueryItem(name: "agreedIds",
                                      value: Self.encodeNames(agreedIDs)))
        }
        if !departed.isEmpty {
            items.append(URLQueryItem(name: "gone", value: Self.encodeNames(departed)))
        }
        if let revision {
            items.append(URLQueryItem(name: "rev", value: String(revision)))
        }
        components.queryItems = items
        guard let url = components.url else { return nil }
        if url.absoluteString.count <= 5000 { return url }
        // Oversize (large groups / long names): drop the base64 JSON roster —
        // `p=` + `pids=` carry the same data far more compactly — instead of
        // hard-failing the whole send.
        components.queryItems = items.filter { $0.name != "pj" }
        if let slim = components.url, slim.absoluteString.count <= 5000 { return slim }
        // Still oversize: sacrifice the departure gossip before failing the
        // send outright — tombstones also travel device-locally, so losing
        // the gossip degrades propagation, not correctness.
        components.queryItems = items.filter { $0.name != "pj" && $0.name != "gone" }
        guard let slimmer = components.url, slimmer.absoluteString.count <= 5000 else { return nil }
        return slimmer
    }

    private static func coordinateString(_ value: Double) -> String {
        String(format: "%.6f", value)
    }

    /// Characters that survive percent-encoding inside a participant token.
    /// `:` and `,` are the field/record separators, so they must be escaped
    /// when they appear inside a name.
    private static let participantNameAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: ":,&=?#")
        return set
    }()

    static func encodeParticipants(_ participants: [Participant]) -> String {
        participants.map { p in
            let name = p.name.addingPercentEncoding(withAllowedCharacters: participantNameAllowed) ?? p.name
            let base = "\(name):\(coordinateString(p.latitude)):\(coordinateString(p.longitude))"
            return p.needsRide ? "\(base):ride" : base
        }.joined(separator: ",")
    }

    static func decodeParticipants(_ raw: String) -> [Participant] {
        raw.split(separator: ",", omittingEmptySubsequences: true).compactMap { entry in
            let parts = entry.split(separator: ":", omittingEmptySubsequences: false)
            guard (parts.count == 3 || parts.count == 4),
                  let lat = Double(parts[1]),
                  let lon = Double(parts[2])
            else { return nil }
            let raw = String(parts[0])
            let name = raw.removingPercentEncoding ?? raw
            let needsRide = parts.count == 4 && parts[3] == "ride"
            return Participant(id: name, name: name, latitude: lat, longitude: lon, needsRide: needsRide)
        }
    }

    static func encodeParticipantJSON(_ participants: [Participant]) -> String? {
        guard let data = try? JSONEncoder().encode(participants) else { return nil }
        return data.base64EncodedString()
    }

    static func decodeParticipantJSON(_ raw: String) -> [Participant]? {
        guard let data = Data(base64Encoded: raw) else { return nil }
        return try? JSONDecoder().decode([Participant].self, from: data)
    }

    static func encodeNames(_ names: [String]) -> String {
        names.map { name in
            name.addingPercentEncoding(withAllowedCharacters: participantNameAllowed) ?? name
        }.joined(separator: ",")
    }

    static func decodeNames(_ raw: String) -> [String] {
        raw.split(separator: ",", omittingEmptySubsequences: true).map { raw in
            let s = String(raw)
            return s.removingPercentEncoding ?? s
        }
    }

    init(
        text: String,
        latitude: Double,
        longitude: Double,
        senderName: String? = nil,
        senderID: String? = nil,
        kind: Kind? = nil,
        senderCoordinate: CLLocationCoordinate2D? = nil,
        action: Action = .invite,
        messageType: MessageType? = nil,
        participants: [Participant] = [],
        agreedNames: [String] = [],
        agreedIDs: [String] = [],
        revision: Int? = nil,
        departed: [String] = []
    ) {
        self.text = text
        self.latitude = latitude
        self.longitude = longitude
        self.senderName = senderName
        self.senderID = senderID
        let resolvedKind = kind ?? (text == "I'm in" ? .participant : .place)
        self.kind = resolvedKind
        self.senderLatitude = senderCoordinate?.latitude
        self.senderLongitude = senderCoordinate?.longitude
        self.action = action
        self.messageType = messageType ?? Self.inferMessageType(kind: resolvedKind, action: action)
        self.participants = participants
        self.agreedNames = agreedNames
        self.agreedIDs = agreedIDs
        self.revision = revision
        self.departed = departed
    }

    init?(url: URL) {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              c.scheme == "https" || c.scheme == "file" || c.scheme == "tween",
              let items = c.queryItems,
              let t = items.first(where: { $0.name == "t" })?.value,
              let lat = items.first(where: { $0.name == "lat" })?.value.flatMap(Double.init),
              let lon = items.first(where: { $0.name == "lon" })?.value.flatMap(Double.init),
              url.absoluteString.count <= 5000
        else { return nil }
        self.text = t
        self.latitude = lat
        self.longitude = lon
        let senderName = items.first(where: { $0.name == "from" })?.value
        self.senderName = senderName
        self.senderID = items.first(where: { $0.name == "fromId" })?.value
        let resolvedKind: Kind
        if let rawKind = items.first(where: { $0.name == "kind" })?.value,
           let kind = Kind(rawValue: rawKind) {
            resolvedKind = kind
        } else {
            resolvedKind = t == "I'm in" ? .participant : .place
        }
        self.kind = resolvedKind
        self.senderLatitude = items.first(where: { $0.name == "slat" })?.value.flatMap(Double.init)
        self.senderLongitude = items.first(where: { $0.name == "slon" })?.value.flatMap(Double.init)
        let resolvedAction: Action
        if let rawAction = items.first(where: { $0.name == "action" })?.value,
           let action = Action(rawValue: rawAction) {
            resolvedAction = action
        } else {
            resolvedAction = .invite
        }
        self.action = resolvedAction

        // Group-aware fields. The presence of `type=` is the signal that the
        // sender's build understands the new format and intentionally said
        // what it meant; absence means the URL was produced by a pre-group
        // build that we need to interpret charitably.
        let isGroupAwareURL = items.contains(where: { $0.name == "type" })

        if let rawType = items.first(where: { $0.name == "type" })?.value,
           let type = MessageType(rawValue: rawType) {
            self.messageType = type
        } else {
            self.messageType = Self.inferMessageType(kind: resolvedKind, action: resolvedAction)
        }

        if let rawPJ = items.first(where: { $0.name == "pj" })?.value,
           let decoded = Self.decodeParticipantJSON(rawPJ) {
            self.participants = decoded
        } else if let rawP = items.first(where: { $0.name == "p" })?.value, !rawP.isEmpty {
            var decoded = Self.decodeParticipants(rawP)
            // The compact format collapses id → name; restore real identity
            // from the aligned `pids=` list when the sender provided one.
            if let rawIDs = items.first(where: { $0.name == "pids" })?.value {
                let ids = Self.decodeNames(rawIDs)
                if ids.count == decoded.count {
                    decoded = zip(decoded, ids).map { participant, id in
                        Participant(id: id,
                                    name: participant.name,
                                    latitude: participant.latitude,
                                    longitude: participant.longitude,
                                    needsRide: participant.needsRide)
                    }
                }
            }
            self.participants = decoded
        } else if isGroupAwareURL {
            // New-format URL deliberately carried no participants.
            self.participants = []
        } else {
            // Legacy fallback: reconstruct a 1-element participants array from
            // the sender's coord so downstream code can treat both formats the
            // same way.
            let senderLat = items.first(where: { $0.name == "slat" })?.value.flatMap(Double.init)
            let senderLon = items.first(where: { $0.name == "slon" })?.value.flatMap(Double.init)
            if let name = senderName, let sLat = senderLat, let sLon = senderLon {
                self.participants = [Participant(id: name, name: name, latitude: sLat, longitude: sLon)]
            } else if let name = senderName, resolvedKind == .participant {
                // Legacy "I'm in" — main coord IS the sender's coord.
                self.participants = [Participant(id: name, name: name, latitude: lat, longitude: lon)]
            } else {
                self.participants = []
            }
        }

        if let rawAgreed = items.first(where: { $0.name == "agreed" })?.value, !rawAgreed.isEmpty {
            self.agreedNames = Self.decodeNames(rawAgreed)
        } else {
            self.agreedNames = []
        }
        if let rawAgreedIDs = items.first(where: { $0.name == "agreedIds" })?.value, !rawAgreedIDs.isEmpty {
            self.agreedIDs = Self.decodeNames(rawAgreedIDs)
        } else {
            self.agreedIDs = []
        }
        self.revision = items.first(where: { $0.name == "rev" })?.value.flatMap(Int.init)
        self.departed = items.first(where: { $0.name == "gone" })?.value.map(Self.decodeNames) ?? []
    }

    private static func inferMessageType(kind: Kind, action: Action) -> MessageType {
        switch (kind, action) {
        case (.participant, _): return .invite
        case (.place, .invite):  return .propose
        case (.place, .agree):   return .agree
        }
    }
}
