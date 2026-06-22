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

    public init(
        id: UUID = UUID(),
        eventKitID: String? = nil,
        title: String = "",
        startDate: Date,
        endDate: Date,
        isAllDay: Bool = false,
        location: String? = nil,
        eventKitNotes: String? = nil
    ) {
        self.id = id
        self.eventKitID = eventKitID
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.isAllDay = isAllDay
        self.location = location
        self.eventKitNotes = eventKitNotes
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
