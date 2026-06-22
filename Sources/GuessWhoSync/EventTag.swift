import Foundation

/// A user-applied tag on an event. Tags are stored as ordinary field-instance
/// cells whose `type` is `.note` and whose `field` name is the well-known
/// `GuessWhoSync.eventTagFieldName` (`"tag"`). Each tag has its own UUID and
/// lives in its own cell, so edits, deletes, and concurrent merges operate
/// per-tag instead of fighting over a single packed value.
public struct EventTag: Hashable, Sendable {
    /// Per-instance UUID — the field-instance cell key for this tag.
    public let id: UUID
    /// The tag's user-visible text — the inner `value` string of the `.note`
    /// cell whose `field == GuessWhoSync.eventTagFieldName`.
    public let text: String
    /// Creation timestamp from the cell's underlying `SidecarField`. Optional
    /// because the field stores it as Date but legacy data may omit it.
    public let createdAt: Date?
    /// Mirrors `ContactNote.deletedAt` — non-nil for soft-deleted tags.
    /// `tags(at:)` excludes deleted instances; this field is exposed for
    /// raw audit only.
    public let deletedAt: Date?

    public init(
        id: UUID,
        text: String,
        createdAt: Date? = nil,
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
        self.deletedAt = deletedAt
    }
}
