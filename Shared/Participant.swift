import Foundation
import CoreLocation

/// One person who has tapped "I'm in" in an iMessage conversation.
///
/// The id is conversation-scoped — locally it's the participant's UUID from
/// `MSConversation` (`localParticipantIdentifier` for me, an entry from
/// `remoteParticipantIdentifiers` for others). When serialised into a
/// `TweenState` URL the id becomes the display name, because UUIDs aren't
/// preserved across iMessage delivery; cross-message identity is therefore
/// by name (same-name collisions degrade gracefully — the second "John"
/// just overwrites the first in the participant list, which is fine for v1).
struct Participant: Codable, Equatable, Identifiable, Hashable {
    let id: String
    let name: String
    let latitude: Double
    let longitude: Double

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    init(id: String, name: String, latitude: Double, longitude: Double) {
        self.id = id
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
    }

    init(id: String, name: String, coordinate: CLLocationCoordinate2D) {
        self.init(id: id, name: name, latitude: coordinate.latitude, longitude: coordinate.longitude)
    }
}
