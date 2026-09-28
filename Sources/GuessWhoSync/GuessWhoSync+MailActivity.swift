import Foundation

/// What one `GuessWhoSync.recordMailActivity(_:at:)` call changed.
public struct MailActivityWriteOutcome: Sendable, Equatable {
    /// This delivery's activity cell was created or its stored value changed,
    /// and the cell is inside the retention window.
    public let activityChanged: Bool
    /// How many OLDER activities already stored were removed by retention.
    public let prunedActivityCount: Int
    /// The `lastInteracted` cell moved to the message's received time.
    public let lastInteractedChanged: Bool
    /// The contact's `lastInteracted` after the call (changed or not).
    public let lastInteracted: Date?

    /// The contact's stored activity list changed (an activity was added or
    /// changed, or older ones were removed).
    public var activitiesChanged: Bool { activityChanged || prunedActivityCount > 0 }

    /// True when the envelope was written. False means the call was a no-op:
    /// a repeat delivery, or a message too old to keep, that moved nothing.
    public var didWrite: Bool { activitiesChanged || lastInteractedChanged }
}

extension GuessWhoSync {
    /// Records `activity` on the contact envelope at `key` and advances the
    /// contact's `lastInteracted` to `activity.receivedAt`, in ONE key-locked
    /// read-modify-write of the raw cell map (every other cell is preserved;
    /// docs/sidecar-compatibility.md). The synced format and rules are in
    /// docs/mail-activity.md.
    ///
    /// - The activity cell is keyed by the Message-ID-derived id, so a repeat
    ///   delivery lands on the same cell. A repeat onto a live cell this build
    ///   decodes writes only this build's keys over the stored value object:
    ///   keys a newer build added survive, and a stored subject or Mail link
    ///   survives a delivery without one. An unchanged object writes nothing;
    ///   a changed one is stamped with the write time so it wins a cross-device
    ///   last-writer-wins merge. A soft-deleted cell stays deleted (a repeat
    ///   never undeletes), and a live cell this build cannot decode (an
    ///   unknown direction, say) is never rewritten.
    /// - Retention keeps the newest `MailActivity.retentionLimit` decodable
    ///   live activities and physically removes older decodable live ones in
    ///   this same write. Soft-deleted and undecodable cells are never removed
    ///   or counted. A delivery that would rank outside the window is not added.
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
            let stored = existing?.fields ?? [:]
            var fields = stored

            // The value to store for this delivery, or nil to leave the cell.
            let newValue: JSONValue?
            if let current = stored[activity.cellKey] {
                if current.deletedAt == nil,
                   MailActivity(cellKey: activity.cellKey, cell: current) != nil,
                   case .object(let object) = current.value {
                    let overlaid = activity.cellValue(overlaying: object)
                    newValue = overlaid == current.value ? nil : overlaid
                } else {
                    newValue = nil
                }
            } else {
                newValue = activity.cellValue
            }
            if let newValue {
                fields[activity.cellKey] = SidecarCell(
                    value: newValue,
                    modifiedAt: Date(),
                    modifiedBy: deviceID
                )
            }

            let removedKeys = Self.pruneMailActivities(&fields)
            // A just-added cell that ranked outside the window was never
            // stored, so it is neither a change nor a prune.
            let activityChanged = newValue != nil && fields[activity.cellKey] != nil
            let prunedActivityCount = removedKeys.filter { stored[$0] != nil }.count

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

            let outcome = MailActivityWriteOutcome(
                activityChanged: activityChanged,
                prunedActivityCount: prunedActivityCount,
                lastInteractedChanged: lastInteractedChanged,
                lastInteracted: lastInteracted
            )
            if outcome.didWrite {
                try ctx.write(
                    SidecarEnvelope(
                        schemaVersion: 1,
                        entityID: existing?.entityID ?? key.id,
                        fields: fields
                    )
                )
            }
            return outcome
        }
    }

    /// Removes every decodable live mail activity cell that ranks below the
    /// newest `MailActivity.retentionLimit`, and returns the removed keys.
    /// Soft-deleted and undecodable cells are left alone and do not count
    /// toward the limit.
    private static func pruneMailActivities(_ fields: inout [String: SidecarCell]) -> [String] {
        let live = fields.compactMap { cellKey, cell -> (key: String, activity: MailActivity)? in
            guard cell.deletedAt == nil,
                  let activity = MailActivity(cellKey: cellKey, cell: cell) else { return nil }
            return (cellKey, activity)
        }
        guard live.count > MailActivity.retentionLimit else { return [] }
        let removed = live
            .sorted { $0.activity.isNewer(than: $1.activity) }
            .dropFirst(MailActivity.retentionLimit)
            .map(\.key)
        for cellKey in removed { fields.removeValue(forKey: cellKey) }
        return removed
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
        return live.sorted { $0.isNewer(than: $1) }
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
