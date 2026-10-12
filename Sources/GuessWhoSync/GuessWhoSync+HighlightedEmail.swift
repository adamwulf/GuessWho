import Foundation

extension GuessWhoSync {
    /// Keeps `email` on the contact envelope at `key`, in ONE key-locked
    /// read-modify-write of the raw cell map (every other cell is preserved;
    /// docs/sidecar-compatibility.md). Returns true when it wrote. The synced
    /// format and rules are in docs/highlighted-emails.md.
    ///
    /// - The cell is keyed by the Message-ID-derived id, so a repeat drop
    ///   lands on the same cell. A repeat onto a live cell this build decodes
    ///   writes only this build's keys over the stored value object: the
    ///   stored `highlightedAt` is kept, a stored optional value survives a
    ///   drop without one, and keys a newer build added survive. An unchanged
    ///   object writes nothing; a changed one is stamped with the write time.
    /// - A soft-deleted cell is REVIVED with a fresh live cell holding this
    ///   drop's full value: a drop is an explicit user action, so re-dropping
    ///   a removed email brings it back.
    /// - A live cell this build cannot decode is never rewritten.
    /// - Never touches `lastInteracted` or any other cell, and keeps every
    ///   email (no retention limit).
    ///
    /// Mints the envelope on first write (`entityID = key.id`), like `addField`.
    @discardableResult
    public func highlightEmail(_ email: HighlightedEmail, at key: SidecarKey) throws -> Bool {
        try withKeyLocked(key) { ctx in
            let existing = try ctx.read()

            // The value to store for this drop, or nil to leave the cell.
            let newValue: JSONValue?
            if let current = existing?.fields[email.cellKey] {
                if current.deletedAt != nil {
                    newValue = email.cellValue
                } else if HighlightedEmail(cellKey: email.cellKey, cell: current) != nil,
                          case .object(let object) = current.value {
                    let overlaid = email.cellValue(overlaying: object)
                    newValue = overlaid == current.value ? nil : overlaid
                } else {
                    newValue = nil
                }
            } else {
                newValue = email.cellValue
            }
            guard let newValue else { return false }

            var fields = existing?.fields ?? [:]
            fields[email.cellKey] = SidecarCell(
                value: newValue,
                modifiedAt: Date(),
                modifiedBy: deviceID
            )
            try ctx.write(
                SidecarEnvelope(
                    schemaVersion: 1,
                    entityID: existing?.entityID ?? key.id,
                    fields: fields
                )
            )
            return true
        }
    }

    /// Async overload of `highlightEmail(_:at:)` that hops the coordinated
    /// read-modify-write to a background queue, off the caller's actor. Same
    /// continuation pattern as `recordMailActivity(_:at:)`.
    @discardableResult
    public func highlightEmail(_ email: HighlightedEmail, at key: SidecarKey) async throws -> Bool {
        try await withCheckedThrowingContinuation { [self] continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result: Bool = try self.highlightEmail(email, at: key)
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Removes the highlighted email `id` from the contact envelope at `key`
    /// with a tombstone: the value is kept, `deletedAt` and `modifiedAt` are
    /// set to now, `modifiedBy` to this device. Returns true when it wrote;
    /// false (no write) when the cell is missing or already deleted.
    ///
    /// The cell is never removed physically: the sidecar merge is a
    /// cell-by-cell union, so a peer still holding the live cell would bring
    /// a removed cell back, while the tombstone wins the merge by its later
    /// `modifiedAt`.
    @discardableResult
    public func removeHighlightedEmail(id: UUID, at key: SidecarKey) throws -> Bool {
        let cellKey = HighlightedEmail.cellKey(for: id)
        return try withKeyLocked(key) { ctx in
            guard let existing = try ctx.read(),
                  let current = existing.fields[cellKey],
                  current.deletedAt == nil
            else { return false }

            let now = Date()
            var fields = existing.fields
            fields[cellKey] = SidecarCell(
                value: current.value,
                modifiedAt: now,
                modifiedBy: deviceID,
                deletedAt: now
            )
            try ctx.write(
                SidecarEnvelope(
                    schemaVersion: 1,
                    entityID: existing.entityID,
                    fields: fields
                )
            )
            return true
        }
    }

    /// Async overload of `removeHighlightedEmail(id:at:)` that hops the
    /// coordinated read-modify-write to a background queue, off the caller's
    /// actor.
    @discardableResult
    public func removeHighlightedEmail(id: UUID, at key: SidecarKey) async throws -> Bool {
        try await withCheckedThrowingContinuation { [self] continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result: Bool = try self.removeHighlightedEmail(id: id, at: key)
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Live (non-deleted), decodable highlighted emails on the envelope at
    /// `key`, in the one public order (`HighlightedEmail.isNewer(than:)`). A
    /// pure read: a missing envelope returns `[]` and mints nothing.
    public func highlightedEmails(at key: SidecarKey) throws -> [HighlightedEmail] {
        guard let envelope = try sidecars.read(key) else { return [] }
        let live = envelope.fields.compactMap { cellKey, cell -> HighlightedEmail? in
            guard cell.deletedAt == nil else { return nil }
            return HighlightedEmail(cellKey: cellKey, cell: cell)
        }
        return live.sorted { $0.isNewer(than: $1) }
    }

    /// Async overload of `highlightedEmails(at:)` that hops the coordinated
    /// read to a background queue, off the caller's actor.
    public func highlightedEmails(at key: SidecarKey) async throws -> [HighlightedEmail] {
        try await withCheckedThrowingContinuation { [self] continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result: [HighlightedEmail] = try self.highlightedEmails(at: key)
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
