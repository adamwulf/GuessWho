import Foundation
import CryptoKit

public struct Event: Hashable, Sendable, Codable {
    /// GuessWho event UUID — the sidecar key. Minted at create. Lowercased
    /// via `SidecarKey.init`'s `.event` branch on every boundary.
    public var id: UUID

    /// Optional pointer OUT to an EventKit event. nil for manual ("Add Other")
    /// events. Set when the user links an event from their calendar. Never
    /// auto-cleared, even when the EventKit event is deleted (Option C).
    public var eventKitID: String?

    public var title: String
    public var startDate: Date
    public var endDate: Date
    public var isAllDay: Bool
    public var location: String?

    /// EventKit's own notes string. Display-only mirror of `EKEvent.notes`;
    /// distinct from GuessWho event notes (which are sidecar field-instances).
    public var eventKitNotes: String?

    /// EventKit attendees mirrored from `EKEvent.attendees`. Read-only from
    /// the calendar — GuessWho never writes these back. Empty for manual
    /// (sidecar-only) events and for calendar events with no invitees.
    public var attendees: [EventAttendee]

    /// Display name of the calendar the event lives in (`EKEvent.calendar.title`).
    /// nil for manual (sidecar-only) events and for calendar events whose
    /// calendar can't be resolved. Read-only mirror — never written back.
    /// Lets the UI disambiguate the same event duplicated across several
    /// calendars (e.g. one copy per audience the user shares with).
    public var calendarName: String?

    /// Hex string (`#RRGGBB`) of the event's calendar color
    /// (`EKCalendar.cgColor`). nil for manual events and when no color is
    /// available. Paired with `calendarName` so the UI can render a colored
    /// swatch matching Calendar.app. Read-only mirror — never written back.
    public var calendarColorHex: String?

    /// When the event record came into existence. For calendar-sourced
    /// events this is `EKEvent.creationDate`; for manual (sidecar-only)
    /// events it is derived from the earliest cell `createdAt` on the
    /// event's envelope. nil when neither source carries a stamp (e.g. a
    /// calendar event whose EKEvent reports no creation date). Backs the
    /// events list's "Recently Added" sort.
    public var createdAt: Date?

    /// When the user last opened this event's detail in the app, read off
    /// the sidecar's `lastViewed` cell. nil until first viewed (including
    /// every ephemeral, pre-adoption EventKit row — a view mints the
    /// sidecar and stamps it). Backs the events list's "Last Viewed" sort.
    public var lastViewedAt: Date?

    public init(
        id: UUID = UUID(),
        eventKitID: String? = nil,
        title: String = "",
        startDate: Date,
        endDate: Date,
        isAllDay: Bool = false,
        location: String? = nil,
        eventKitNotes: String? = nil,
        attendees: [EventAttendee] = [],
        calendarName: String? = nil,
        calendarColorHex: String? = nil,
        createdAt: Date? = nil,
        lastViewedAt: Date? = nil
    ) {
        self.id = id
        self.eventKitID = eventKitID
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.isAllDay = isAllDay
        self.location = location
        self.eventKitNotes = eventKitNotes
        self.attendees = attendees
        self.calendarName = calendarName
        self.calendarColorHex = calendarColorHex
        self.createdAt = createdAt
        self.lastViewedAt = lastViewedAt
    }
}

/// One EventKit attendee. Sourced from `EKParticipant`; `name` is the
/// participant's display name and `email` is parsed out of
/// `participant.url` when it's a `mailto:` URL. Email is stored lowercased
/// so attendee↔contact matching is a trivial string compare.
public struct EventAttendee: Hashable, Sendable, Codable {
    public var name: String
    public var email: String?

    public init(name: String, email: String? = nil) {
        self.name = name
        self.email = email?.lowercased()
    }
}

extension Event {
    /// True iff this event points at an EventKit event (regardless of whether
    /// that event currently exists).
    public var isLinked: Bool { eventKitID != nil }

    /// Derive a stable placeholder UUID from an `eventKitID` string. Used by
    /// the EventKit adapter (`toEvent`) and by the orchestrator's windowed
    /// read (`eventsWindow`) for ephemeral display rows so SwiftUI identity is
    /// stable across repeat fetches. NEVER persisted — the real sidecar UUID
    /// lives in `id` once a sidecar is minted.
    ///
    /// Implementation: SHA-256(eventKitID), first 16 bytes formatted as a
    /// UUID per RFC 4122 (version 5, RFC 4122 variant). Same input always
    /// yields the same UUID across calls.
    public static func stableID(forEventKitID eventKitID: String) -> UUID {
        let digest = SHA256.hash(data: Data(eventKitID.utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
