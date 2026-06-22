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
///   * `agreedNames` lists who has agreed to the current proposal; combined
///     with the proposer (implicitly agreed) it yields full consensus.
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

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var senderCoordinate: CLLocationCoordinate2D? {
        guard let senderLatitude, let senderLongitude else { return nil }
        return CLLocationCoordinate2D(latitude: senderLatitude, longitude: senderLongitude)
    }

    var participantCoordinate: CLLocationCoordinate2D? {
        kind == .participant ? coordinate : senderCoordinate
    }

    var representsParticipantLocation: Bool {
        kind == .participant
    }

    /// True when every non-proposer participant has agreed to the current
    /// proposal. Returns false for non-proposal message types.
    var isFullyAgreed: Bool {
        guard messageType == .agree, !participants.isEmpty else { return false }
        let proposer = senderName ?? ""
        let needToAgree = participants.map(\.name).filter { $0 != proposer }
        guard !needToAgree.isEmpty else { return false }
        return needToAgree.allSatisfy { agreedNames.contains($0) }
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
        if let senderLatitude, let senderLongitude {
            items.append(URLQueryItem(name: "slat", value: Self.coordinateString(senderLatitude)))
            items.append(URLQueryItem(name: "slon", value: Self.coordinateString(senderLongitude)))
        }
        // Group-aware params.
        items.append(URLQueryItem(name: "type", value: messageType.rawValue))
        if !participants.isEmpty {
            items.append(URLQueryItem(name: "p", value: Self.encodeParticipants(participants)))
        }
        if !agreedNames.isEmpty {
            items.append(URLQueryItem(name: "agreed",
                                      value: Self.encodeNames(agreedNames)))
        }
        components.queryItems = items
        guard let url = components.url, url.absoluteString.count <= 5000 else { return nil }
        return url
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
            return "\(name):\(coordinateString(p.latitude)):\(coordinateString(p.longitude))"
        }.joined(separator: ",")
    }

    static func decodeParticipants(_ raw: String) -> [Participant] {
        raw.split(separator: ",", omittingEmptySubsequences: true).compactMap { entry in
            let parts = entry.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 3,
                  let lat = Double(parts[1]),
                  let lon = Double(parts[2])
            else { return nil }
            let raw = String(parts[0])
            let name = raw.removingPercentEncoding ?? raw
            return Participant(id: name, name: name, latitude: lat, longitude: lon)
        }
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
        kind: Kind? = nil,
        senderCoordinate: CLLocationCoordinate2D? = nil,
        action: Action = .invite,
        messageType: MessageType? = nil,
        participants: [Participant] = [],
        agreedNames: [String] = []
    ) {
        self.text = text
        self.latitude = latitude
        self.longitude = longitude
        self.senderName = senderName
        let resolvedKind = kind ?? (text == "I'm in" ? .participant : .place)
        self.kind = resolvedKind
        self.senderLatitude = senderCoordinate?.latitude
        self.senderLongitude = senderCoordinate?.longitude
        self.action = action
        self.messageType = messageType ?? Self.inferMessageType(kind: resolvedKind, action: action)
        self.participants = participants
        self.agreedNames = agreedNames
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

        if let rawP = items.first(where: { $0.name == "p" })?.value, !rawP.isEmpty {
            self.participants = Self.decodeParticipants(rawP)
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
    }

    private static func inferMessageType(kind: Kind, action: Action) -> MessageType {
        switch (kind, action) {
        case (.participant, _): return .invite
        case (.place, .invite):  return .propose
        case (.place, .agree):   return .agree
        }
    }
}
