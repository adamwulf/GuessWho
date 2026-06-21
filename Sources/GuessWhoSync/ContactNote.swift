import Foundation

/// A free-text note attached to a contact or event entity. Notes are stored
/// as ordinary field-instance cells (§7.3) whose `type` is `.note` and whose
/// `field` name is the well-known `GuessWhoSync.contactNoteFieldName`. Each
/// note has its own UUID and lives in its own cell, so edits, deletes, and
/// concurrent merges operate per-note instead of fighting over a single
/// packed value.
///
/// Body is the decoded JSON string payload; `createdAt` is the cell's
/// inner `createdAt` timestamp (§5.2). Soft-deleted notes carry a
/// non-nil `deletedAt`; callers that want the displayable list should use
/// `GuessWhoSync.notes(at:)` which filters tombstones and sorts by
/// `createdAt` ascending.
public struct ContactNote: Hashable, Sendable {
    public let id: UUID
    public let body: String
    public let createdAt: Date
    public let modifiedAt: Date
    public let modifiedBy: String
    public let deletedAt: Date?

    public init(
        id: UUID,
        body: String,
        createdAt: Date,
        modifiedAt: Date,
        modifiedBy: String,
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.body = body
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.modifiedBy = modifiedBy
        self.deletedAt = deletedAt
    }

    public var isDeleted: Bool { deletedAt != nil }
}
