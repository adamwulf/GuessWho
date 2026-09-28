import Foundation

/// What one `GuessWhoSync.recordMailActivity(_:at:)` call changed.
public struct MailActivityWriteOutcome: Sendable, Equatable {
    /// The activity cell was created or its payload replaced.
    public let activityChanged: Bool
    /// The `lastInteracted` cell moved to the message's received time.
    public let lastInteractedChanged: Bool
    /// The contact's `lastInteracted` after the call (changed or not).
    public let lastInteracted: Date?

    /// True when the envelope was written. False means the call was a no-op
    /// (a duplicate delivery of a message already recorded).
    public var didWrite: Bool { activityChanged || lastInteractedChanged }
}

extension GuessWhoSync {
    /// Records `activity` on the contact envelope at `key` and advances the
    /// contact's `lastInteracted` to `activity.receivedAt`, in ONE key-locked
    /// read-modify-write of the raw cell map (every other cell is preserved;
    /// docs/sidecar-compatibility.md).
    ///
    /// - The activity cell is keyed by the Message-ID-derived id, so a repeat
    ///   delivery upserts the same cell. An identical payload writes nothing; a
    ///   changed payload replaces it, stamped with the write time so the
    ///   newer payload wins a cross-device last-writer-wins merge. A
    ///   soft-deleted cell is left deleted: a repeat delivery never brings
    ///   back an activity another build removed.
    /// - `lastInteracted` only moves FORWARD: an older message processed late
    ///   never rewinds a newer interaction. When it moves, the cell's value and
    ///   its `modifiedAt` are both the received time — the same value ==
    ///   `modifiedAt` shape every timestamp stamp writes, so a cross-device
    ///   merge keeps the latest interaction.
    ///
    /// Mints the envelope on first write (`entityID = key.id`), like `addField`.
    @discardableResult
    public func recordMailActivity(_ activity: MailActivity, at key: SidecarKey) throws -> MailActivityWriteOutcome {
        try withKeyLocked(key) { ctx in
            let existing = try ctx.read()
            var fields = existing?.fields ?? [:]

            let newValue = activity.cellValue
            let activityChanged: Bool
            if let current = fields[activity.cellKey] {
                activityChanged = current.deletedAt == nil && current.value != newValue
            } else {
                activityChanged = true
            }
            if activityChanged {
                fields[activity.cellKey] = SidecarCell(
                    value: newValue,
                    modifiedAt: Date(),
                    modifiedBy: deviceID
                )
            }

            var lastInteracted = ContactTimestamps.decodeDate(fields[ContactTimestamps.lastInteractedKey])
            let lastInteractedChanged = lastInteracted.map { $0 < activity.receivedAt } ?? true
            if lastInteractedChanged {
                fields[ContactTimestamps.lastInteractedKey] = SidecarCell(
                    value: .string(SidecarISO8601.string(from: activity.receivedAt)),
                    modifiedAt: activity.receivedAt,
                    modifiedBy: deviceID
                )
                lastInteracted = activity.receivedAt
            }

            if activityChanged || lastInteractedChanged {
                try ctx.write(
                    SidecarEnvelope(
                        schemaVersion: 1,
                        entityID: existing?.entityID ?? key.id,
                        fields: fields
                    )
                )
            }
            return MailActivityWriteOutcome(
                activityChanged: activityChanged,
                lastInteractedChanged: lastInteractedChanged,
                lastInteracted: lastInteracted
            )
        }
    }

    /// Async overload of `recordMailActivity(_:at:)` that hops the coordinated
    /// read-modify-write to a background queue, so a batch of queued messages
    /// never blocks the caller's actor. Same continuation pattern as
    /// `links(at:)`.
    @discardableResult
    public func recordMailActivity(_ activity: MailActivity, at key: SidecarKey) async throws -> MailActivityWriteOutcome {
        try await withCheckedThrowingContinuation { [self] continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result: MailActivityWriteOutcome = try self.recordMailActivity(activity, at: key)
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Live (non-deleted) mail activities on the envelope at `key`, newest
    /// `receivedAt` first; ties break on `id` for a stable order across
    /// devices. A pure read: a missing envelope returns `[]` and mints nothing.
    public func mailActivities(at key: SidecarKey) throws -> [MailActivity] {
        guard let envelope = try sidecars.read(key) else { return [] }
        let live = envelope.fields.compactMap { cellKey, cell -> MailActivity? in
            guard cell.deletedAt == nil else { return nil }
            return MailActivity(cellKey: cellKey, cell: cell)
        }
        return live.sorted { lhs, rhs in
            if lhs.receivedAt != rhs.receivedAt { return lhs.receivedAt > rhs.receivedAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    /// Async overload of `mailActivities(at:)` that hops the coordinated read
    /// to a background queue, off the caller's actor.
    public func mailActivities(at key: SidecarKey) async throws -> [MailActivity] {
        try await withCheckedThrowingContinuation { [self] continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result: [MailActivity] = try self.mailActivities(at: key)
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
