import Foundation
import EventKit
import CoreLocation

/// "Calendar sync" — drops the agreed meetup into the user's calendar with its
/// spot, time, and who's coming.
///
/// Write-only access (`requestWriteOnlyAccessToEvents`, iOS 17+): Tween has no
/// reason to READ anyone's calendar, and asking for full access to write one
/// event is the kind of over-ask that gets an app rejected and deservedly
/// distrusted. Nothing leaves the device (constraint 8).
enum CalendarExport {
    enum Failure: Error, Equatable {
        case accessDenied
        case saveFailed(String)
    }

    /// Default block length when the meetup has a start but no stated end.
    static let defaultDuration: TimeInterval = 60 * 60

    static func requestAccess(store: EKEventStore = EKEventStore()) async -> Bool {
        do {
            if #available(iOS 17.0, *) {
                return try await store.requestWriteOnlyAccessToEvents()
            } else {
                return try await store.requestAccess(to: .event)
            }
        } catch {
            return false
        }
    }

    /// Adds the meetup and returns the created event's identifier.
    ///
    /// `attendees` are written into the notes, NOT as EKParticipants — those
    /// are read-only in EventKit and would silently drop, leaving the user
    /// thinking Tween had invited people it never did.
    @discardableResult
    static func add(spotName: String,
                    coordinate: CLLocationCoordinate2D?,
                    arrivalDate: Date,
                    attendees: [String] = [],
                    store: EKEventStore = EKEventStore()) async throws -> String {
        guard await requestAccess(store: store) else { throw Failure.accessDenied }

        let event = EKEvent(eventStore: store)
        event.title = "Meet at \(spotName)"
        event.startDate = arrivalDate
        event.endDate = arrivalDate.addingTimeInterval(defaultDuration)
        event.calendar = store.defaultCalendarForNewEvents

        if let coordinate {
            let structured = EKStructuredLocation(title: spotName)
            structured.geoLocation = CLLocation(latitude: coordinate.latitude,
                                                longitude: coordinate.longitude)
            event.structuredLocation = structured
        } else {
            event.location = spotName
        }

        if !attendees.isEmpty {
            event.notes = "With \(formatted(attendees)).\nPlanned in Tween."
        } else {
            event.notes = "Planned in Tween."
        }

        do {
            try store.save(event, span: .thisEvent, commit: true)
        } catch {
            throw Failure.saveFailed(error.localizedDescription)
        }
        return event.eventIdentifier ?? ""
    }

    /// "Kavi", "Kavi and Hassan", "Kavi, Hassan, and Sam".
    static func formatted(_ names: [String]) -> String {
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        default:
            return names.dropLast().joined(separator: ", ") + ", and " + names[names.count - 1]
        }
    }
}
