import Foundation

/// Which of the three per-contact timestamp cells a stamp write targets.
/// Each case maps to one fixed cell key on the contact's §5.2 sidecar
/// envelope (see `ContactTimestamps.<key>`). Public so the orchestrator
/// caller can name the cell without learning the on-disk string.
public enum ContactTimestampKind: Sendable {
    /// The contact's GuessWho data (notes/tags/fields/links) was last edited.
    case modified
    /// The user last interacted with the person/org out in the world (an
    /// event with them, a logged touch).
    case interacted
    /// The user last opened the contact's detail in the app.
    case viewed

    /// The fixed cell key this kind writes/reads.
    var cellKey: String {
        switch self {
        case .modified:    return ContactTimestamps.lastModifiedKey
        case .interacted:  return ContactTimestamps.lastInteractedKey
        case .viewed:      return ContactTimestamps.lastViewedKey
        }
    }
}

/// The three per-contact timestamps GuessWho stamps on the contact sidecar.
///
/// Each is stored as its own fixed-key §5.2 cell carrying an ISO8601 string
/// (`SidecarISO8601`), following the named-cell pattern `Link` uses (fixed
/// string keys, missing cell -> nil, tolerant decode). All three are OPTIONAL
/// and ADDITIVE: an envelope written before these cells existed simply
/// decodes to `nil` for every field, and a write touches only the one cell it
/// targets — every other cell (notes, tags, links, the other timestamps) is
/// preserved. The schema version is NOT bumped for these cells.
public struct ContactTimestamps: Sendable, Equatable {
    /// When the contact's GuessWho data was last edited, or nil if never
    /// stamped (or the cell is absent/unparseable).
    public var lastModified: Date?
    /// When the user last interacted with the contact, or nil.
    public var lastInteracted: Date?
    /// When the user last viewed the contact's detail, or nil.
    public var lastViewed: Date?

    public init(lastModified: Date? = nil, lastInteracted: Date? = nil, lastViewed: Date? = nil) {
        self.lastModified = lastModified
        self.lastInteracted = lastInteracted
        self.lastViewed = lastViewed
    }
}

extension ContactTimestamps {
    // Fixed cell keys on the contact envelope. Stable strings — they are part
    // of the on-disk format and must never change.
    static let lastModifiedKey = "lastModified"
    static let lastInteractedKey = "lastInteracted"
    static let lastViewedKey = "lastViewed"

    /// Decode the three timestamp cells off a contact envelope. TOLERANT, like
    /// `Link.init(from:)`: an absent cell -> nil; a present cell whose value is
    /// not a parseable ISO8601 string -> nil for THAT field only (it never
    /// fails the whole decode and never disturbs the other two fields). A
    /// migration-era envelope carrying none of the three cells therefore yields
    /// `ContactTimestamps(nil, nil, nil)`.
    public init(from envelope: SidecarEnvelope) {
        self.init(
            lastModified: ContactTimestamps.decodeDate(envelope.fields[ContactTimestamps.lastModifiedKey]),
            lastInteracted: ContactTimestamps.decodeDate(envelope.fields[ContactTimestamps.lastInteractedKey]),
            lastViewed: ContactTimestamps.decodeDate(envelope.fields[ContactTimestamps.lastViewedKey])
        )
    }

    /// Read a single timestamp cell's value as a Date, or nil when the cell is
    /// absent, soft-deleted, or carries anything other than a parseable
    /// ISO8601 string. Mirrors `Link`'s tolerant cell decode.
    static func decodeDate(_ cell: SidecarCell?) -> Date? {
        guard let cell, cell.deletedAt == nil else { return nil }
        guard case .string(let raw) = cell.value else { return nil }
        return SidecarISO8601.date(from: raw)
    }
}
