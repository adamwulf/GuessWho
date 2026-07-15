import Foundation

extension GuessWhoSync {
    /// Well-known `field` name used to mark a sidecar field-instance cell
    /// as a contact/event note. Other `.note`-typed fields can coexist on
    /// the same entity (e.g. a future "voicemail transcript" type-`.note`
    /// field) — the notes convenience API uses both `type == .note` AND
    /// `field == contactNoteFieldName` to pick out the user-authored
    /// free-text notes from anything else.
    public static let contactNoteFieldName = "note"

    /// Append a new note to the entity. Mints a fresh per-note UUID, writes
    /// one cell, and returns the UUID so the caller can later edit or
    /// delete that specific note. Empty / whitespace-only bodies are
    /// allowed at this layer — callers (e.g. the UI) trim and gate.
    /// `createdAt` is the note's user-visible date; it defaults to now but
    /// the caller may back- or forward-date it (the UI lets the user pick).
    @discardableResult
    public func addNote(at key: SidecarKey, body: String, createdAt: Date = Date()) throws -> UUID {
        try addField(
            at: key,
            field: Self.contactNoteFieldName,
            type: .note,
            value: .string(body),
            createdAt: createdAt
        )
    }

    /// Edit an existing note's body and, optionally, its date. Preserves the
    /// per-note UUID; bumps `modifiedAt` / `modifiedBy`; undeletes the note
    /// if it was previously soft-deleted (mirrors `setField` semantics). A
    /// non-nil `createdAt` re-stamps the note's user-visible date (which
    /// also re-sorts it in `notes(at:)`); nil preserves the existing date.
    /// Silent no-op if no note with `id` exists at `key`.
    public func editNote(at key: SidecarKey, id: UUID, newBody: String, createdAt: Date? = nil) throws {
        try setField(
            at: key,
            id: id,
            field: Self.contactNoteFieldName,
            value: .string(newBody),
            createdAt: createdAt
        )
    }

    /// Soft-delete a note (tombstone-style): the cell stays so concurrent
    /// peers converge, but it stops appearing in `notes(at:)`. Silent
    /// no-op if no note with `id` exists, or it's already deleted.
    public func deleteNote(at key: SidecarKey, id: UUID) throws {
        try deleteField(at: key, id: id)
    }

    /// Live (non-deleted) notes attached to the entity, sorted by
    /// `createdAt` ascending so the oldest note appears first on a contact
    /// card. Ties on `createdAt` are broken by `id.uuidString` for
    /// deterministic ordering across devices.
    ///
    /// Cells whose inner `value` object is missing the optional
    /// `createdAt` stamp (legacy or future writers) sort to `.distantPast`
    /// rather than being silently dropped — the package promises to
    /// surface any note it can decode at all.
    public func notes(at key: SidecarKey) throws -> [ContactNote] {
        let raw = try fields(at: key)
        let live = raw.compactMap { field -> ContactNote? in
            guard field.type == .note,
                  field.field == Self.contactNoteFieldName,
                  field.deletedAt == nil,
                  case .string(let body) = field.value
            else { return nil }
            return ContactNote(
                id: field.id,
                body: body,
                createdAt: field.createdAt ?? .distantPast,
                modifiedAt: field.modifiedAt,
                modifiedBy: field.modifiedBy,
                deletedAt: nil
            )
        }
        return live.sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    /// All notes — including soft-deleted ones — attached to the entity,
    /// sorted by `createdAt` ascending. Provided for sync/inspection use
    /// cases (reconcile reports, debugging) where the tombstones matter.
    /// Most UI callers want `notes(at:)`.
    public func allNotes(at key: SidecarKey) throws -> [ContactNote] {
        let raw = try fields(at: key)
        let all = raw.compactMap { field -> ContactNote? in
            guard field.type == .note,
                  field.field == Self.contactNoteFieldName,
                  case .string(let body) = field.value
            else { return nil }
            return ContactNote(
                id: field.id,
                body: body,
                createdAt: field.createdAt ?? .distantPast,
                modifiedAt: field.modifiedAt,
                modifiedBy: field.modifiedBy,
                deletedAt: field.deletedAt
            )
        }
        return all.sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }
}
