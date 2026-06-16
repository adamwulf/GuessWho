import Foundation

public final class GuessWhoSync {
    private let contacts: ContactStoreProtocol
    private let events: EventStoreProtocol
    private let sidecars: SidecarStoreProtocol
    private let deviceID: String
    private let sidecarLocks = PerKeyLockTable<SidecarKey>()

    public init(
        contacts: ContactStoreProtocol,
        events: EventStoreProtocol,
        sidecars: SidecarStoreProtocol,
        deviceID: String
    ) {
        self.contacts = contacts
        self.events = events
        self.sidecars = sidecars
        self.deviceID = deviceID
    }

    public func sidecar(at key: SidecarKey) throws -> SidecarEnvelope? {
        try sidecars.read(key)
    }

    // MARK: - Field-instance API (§7.3)
    //
    // Every cell is keyed by a per-instance UUID and carries an inner
    // value object { field, type, value, createdAt } per §5.2. A contact
    // or event may carry zero-to-many instances of any type.

    /// Adds a new field instance. Mints a UUID, writes a cell whose inner
    /// value object is { field, type, value, createdAt }. Returns the
    /// minted UUID.
    @discardableResult
    public func addField(
        at key: SidecarKey,
        field: String,
        type: SidecarFieldType,
        value: JSONValue
    ) throws -> UUID {
        try SidecarField.validate(value: value, against: type)
        return try sidecarLocks.withLock(forKey: key) {
            let existing = try sidecars.read(key)
            let id = UUID()
            let now = Date()
            let inner = SidecarField.makeInnerValue(
                field: field,
                type: type,
                value: value,
                createdAt: now
            )
            let cell = SidecarCell(value: inner, modifiedAt: now, modifiedBy: deviceID)
            var fields = existing?.fields ?? [:]
            fields[id.uuidString] = cell
            let envelope = SidecarEnvelope(
                schemaVersion: 1,
                entityID: existing?.entityID ?? key.id,
                fields: fields
            )
            try sidecars.write(envelope, at: key)
            return id
        }
    }

    /// Mutates an existing field instance's caller-supplied name and/or
    /// value. Reads the existing cell to recover the immutable `type`;
    /// throws `typeValueMismatch` if the new value doesn't match. Bumps
    /// `modifiedAt`/`modifiedBy` and clears `deletedAt` (undelete: writing
    /// to a soft-deleted cell brings it back as live). Silent no-op if the
    /// cell is missing.
    public func setField(
        at key: SidecarKey,
        id: UUID,
        field: String,
        value: JSONValue
    ) throws {
        try sidecarLocks.withLock(forKey: key) {
            guard let existing = try sidecars.read(key),
                  let existingCell = existing.fields[id.uuidString]
            else { return }
            guard let type = SidecarField.type(of: existingCell) else { return }
            try SidecarField.validate(value: value, against: type)

            guard let inner = SidecarField.makeInnerValueForEdit(
                existingCell: existingCell,
                newField: field,
                newValue: value
            ) else { return }

            let cell = SidecarCell(
                value: inner,
                modifiedAt: Date(),
                modifiedBy: deviceID,
                deletedAt: nil
            )
            var fields = existing.fields
            fields[id.uuidString] = cell
            let envelope = SidecarEnvelope(
                schemaVersion: 1,
                entityID: existing.entityID,
                fields: fields
            )
            try sidecars.write(envelope, at: key)
        }
    }

    /// Soft-deletes a field instance by setting cell `deletedAt = now`,
    /// bumping `modifiedAt`/`modifiedBy`. The inner value object is
    /// preserved as a record of what was deleted. Silent no-op if the
    /// cell is missing or already soft-deleted.
    public func deleteField(at key: SidecarKey, id: UUID) throws {
        try sidecarLocks.withLock(forKey: key) {
            guard let existing = try sidecars.read(key),
                  let existingCell = existing.fields[id.uuidString]
            else { return }
            if existingCell.deletedAt != nil { return }

            let now = Date()
            let cell = SidecarCell(
                value: existingCell.value,
                modifiedAt: now,
                modifiedBy: deviceID,
                deletedAt: now
            )
            var fields = existing.fields
            fields[id.uuidString] = cell
            let envelope = SidecarEnvelope(
                schemaVersion: 1,
                entityID: existing.entityID,
                fields: fields
            )
            try sidecars.write(envelope, at: key)
        }
    }

    /// Returns one decoded field by id, or nil if the cell is missing or
    /// has an unknown/malformed `type`. Soft-deleted fields are returned
    /// (callers filter on `deletedAt`).
    public func field(at key: SidecarKey, id: UUID) throws -> SidecarField? {
        guard let envelope = try sidecars.read(key),
              let cell = envelope.fields[id.uuidString]
        else { return nil }
        return SidecarField.decode(id: id, from: cell)
    }

    /// Returns every decoded field in the entity's sidecar, in unspecified
    /// order. Soft-deleted fields are returned. Cells whose `type` is
    /// unknown to this package version are omitted (forward-compatibility).
    public func fields(at key: SidecarKey) throws -> [SidecarField] {
        guard let envelope = try sidecars.read(key) else { return [] }
        var result: [SidecarField] = []
        result.reserveCapacity(envelope.fields.count)
        for (rawID, cell) in envelope.fields {
            guard let id = UUID(uuidString: rawID) else { continue }
            if let decoded = SidecarField.decode(id: id, from: cell) {
                result.append(decoded)
            }
        }
        return result
    }

    // MARK: - Link API (§13)

    /// Creates a link between two entities. Writes one envelope and
    /// returns the minted Link. Never dedups — multiple links between
    /// the same endpoints are allowed.
    @discardableResult
    public func addLink(from a: SidecarKey, to b: SidecarKey, note: String) throws -> Link {
        let id = UUID()
        let key = SidecarKey(kind: .link, id: id.uuidString)
        let now = Date()
        // createdAt is stored as an ISO8601 string with millisecond
        // precision. Round-trip `now` through that string so the returned
        // Link's createdAt matches what link(id:) will read back.
        let createdAtStored = SidecarISO8601.date(from: SidecarISO8601.string(from: now)) ?? now
        let envelope = SidecarEnvelope(
            schemaVersion: 1,
            entityID: key.id,
            fields: [
                Link.endpointAKey: SidecarCell(value: Link.encodeEndpoint(a), modifiedAt: now, modifiedBy: deviceID),
                Link.endpointBKey: SidecarCell(value: Link.encodeEndpoint(b), modifiedAt: now, modifiedBy: deviceID),
                Link.noteKey: SidecarCell(value: .string(note), modifiedAt: now, modifiedBy: deviceID),
                Link.createdAtKey: SidecarCell(
                    value: .string(SidecarISO8601.string(from: createdAtStored)),
                    modifiedAt: now,
                    modifiedBy: deviceID
                ),
            ]
        )
        try sidecarLocks.withLock(forKey: key) {
            try sidecars.write(envelope, at: key)
        }
        return Link(
            id: id,
            endpointA: a,
            endpointB: b,
            note: note,
            createdAt: createdAtStored,
            modifiedAt: now,
            modifiedBy: deviceID
        )
    }

    /// Mutates the note on an existing link. If the link is soft-deleted,
    /// also clears the deletedAt cell (undelete: writes deletedAt cell
    /// with value: null alongside the note write). Silent no-op if the
    /// envelope is missing.
    public func setLinkNote(id: UUID, note: String) throws {
        let key = SidecarKey(kind: .link, id: id.uuidString)
        try sidecarLocks.withLock(forKey: key) {
            guard let existing = try sidecars.read(key) else { return }
            let now = Date()
            var fields = existing.fields
            fields[Link.noteKey] = SidecarCell(
                value: .string(note),
                modifiedAt: now,
                modifiedBy: deviceID
            )
            // Undelete: write deletedAt cell with value: null so LWW recognises
            // this as a fresh live-state write.
            if fields[Link.deletedAtKey] != nil {
                fields[Link.deletedAtKey] = SidecarCell(
                    value: .null,
                    modifiedAt: now,
                    modifiedBy: deviceID
                )
            }
            try sidecars.write(
                SidecarEnvelope(schemaVersion: 1, entityID: existing.entityID, fields: fields),
                at: key
            )
        }
    }

    /// Soft-deletes the link by writing the deletedAt cell with an ISO8601
    /// timestamp value. All other cells are preserved so a future
    /// setLinkNote can undelete without losing the note. Silent no-op if
    /// the link is missing or already soft-deleted.
    public func removeLink(id: UUID) throws {
        let key = SidecarKey(kind: .link, id: id.uuidString)
        try sidecarLocks.withLock(forKey: key) {
            guard let existing = try sidecars.read(key) else { return }
            // Already soft-deleted: silent no-op (no stamp churn).
            if let cell = existing.fields[Link.deletedAtKey], case .string = cell.value {
                return
            }
            let now = Date()
            var fields = existing.fields
            fields[Link.deletedAtKey] = SidecarCell(
                value: .string(SidecarISO8601.string(from: now)),
                modifiedAt: now,
                modifiedBy: deviceID
            )
            try sidecars.write(
                SidecarEnvelope(schemaVersion: 1, entityID: existing.entityID, fields: fields),
                at: key
            )
        }
    }

    /// Returns a single link by id, or nil if the envelope is missing or
    /// malformed. Soft-deleted links are returned; callers filter.
    public func link(id: UUID) throws -> Link? {
        let key = SidecarKey(kind: .link, id: id.uuidString)
        guard let envelope = try sidecars.read(key) else { return nil }
        return Link(from: envelope)
    }

    /// Returns every link whose endpointA or endpointB equals `key`.
    /// Soft-deleted links are returned. O(N links).
    public func links(at endpoint: SidecarKey) throws -> [Link] {
        var result: [Link] = []
        for key in try sidecars.allKeys() where key.kind == .link {
            guard let envelope = try sidecars.read(key) else { continue }
            guard let link = Link(from: envelope) else { continue }
            if link.endpointA == endpoint || link.endpointB == endpoint {
                result.append(link)
            }
        }
        return result
    }

    public func reconcileSidecars() throws -> SidecarReconcileReport {
        var stamped: [SidecarReconcileReport.FileOutcome] = []

        // Iterate keys ourselves and hold the per-key sidecarLock for the full
        // resolver + write window. Without holding the lock for the WHOLE
        // window (resolver invocation through the store's merged-write), a
        // concurrent setField on the same key would slip a write between
        // the store's read-versions and its merged-write and be silently
        // clobbered.
        for key in try sidecars.keysWithUnresolvedConflicts() {
            var reasons: [String] = []
            let outcome = try sidecarLocks.withLock(forKey: key) { () throws -> SidecarReconcileReport.FileOutcome? in
                try sidecars.reconcileConflict(at: key) { versions in
                    var parsed: [SidecarEnvelope] = []
                    var skipped: [Data] = []
                    for bytes in versions {
                        switch parseEnvelope(bytes) {
                        case .ok(let envelope):
                            parsed.append(envelope)
                        case .skip(let reason):
                            skipped.append(bytes)
                            reasons.append(reason)
                        }
                    }

                    guard var folded = parsed.first else {
                        return .leave
                    }
                    for next in parsed.dropFirst() {
                        switch merge(folded, next) {
                        case .success(let combined):
                            folded = combined
                        case .failure(let err):
                            reasons.append("merge failed: \(err)")
                            return .leave
                        }
                    }
                    return .write(merged: folded, skip: skipped)
                }
            }
            if let outcome {
                stamped.append(
                    SidecarReconcileReport.FileOutcome(
                        key: outcome.key,
                        mergedVersionCount: outcome.mergedVersionCount,
                        skippedReasons: outcome.skippedReasons + reasons
                    )
                )
            }
        }

        return SidecarReconcileReport(fileOutcomes: stamped)
    }

    public func reconcileContactIdentities() throws -> IdentityReconcileReport {
        var outcomes: [IdentityReconcileReport.ContactOutcome] = []
        var carriedUUIDs: Set<String> = []

        for contact in try contacts.fetchAll() {
            let outcome = try reconcile(contact: contact)
            outcomes.append(outcome.report)
            carriedUUIDs.formUnion(outcome.carriedUUIDs)
        }

        let orphans = try sidecars.allKeys()
            .filter { $0.kind == .contact && !carriedUUIDs.contains($0.id) }
            .sorted { $0.id < $1.id }

        return IdentityReconcileReport(contactOutcomes: outcomes, orphanSidecars: orphans)
    }

    // Single-contact entry point used by host apps that want explicit,
    // per-contact control. Orphan-sidecar detection is intentionally NOT
    // performed here: it requires the complete set of carried UUIDs across
    // every contact to be meaningful. Use reconcileContactIdentities() when
    // that information is needed.
    public func reconcileContactIdentity(localID: String) throws -> IdentityReconcileReport.ContactOutcome {
        guard let contact = try contacts.fetch(localID: localID) else {
            throw ContactStoreError.contactNotFound(localID: localID)
        }
        return try reconcile(contact: contact).report
    }

    private struct ContactReconcileResult {
        let report: IdentityReconcileReport.ContactOutcome
        let carriedUUIDs: [String]
    }

    private func reconcile(contact original: Contact) throws -> ContactReconcileResult {
        var contact = original
        var uniqueValidUUIDs: [String] = []
        var seenUUIDs: Set<String> = []
        var hadDuplicateUUID = false
        var malformedURLs: [String] = []

        for url in contact.urlAddresses {
            guard url.value.hasPrefix(SidecarKey.guessWhoContactURLPrefix) else { continue }
            if let uuid = SidecarKey.parseGuessWhoContactURL(url.value) {
                if seenUUIDs.insert(uuid).inserted {
                    uniqueValidUUIDs.append(uuid)
                } else {
                    hadDuplicateUUID = true
                }
            } else {
                malformedURLs.append(url.value)
            }
        }

        // Collapse repeat occurrences of the SAME canonical UUID down to one URL entry,
        // so only DIFFERENT canonical UUIDs reach Case D's keep-smaller-delete-larger logic.
        if hadDuplicateUUID {
            var keptUUIDs: Set<String> = []
            contact.urlAddresses.removeAll { url in
                guard url.value.hasPrefix(SidecarKey.guessWhoContactURLPrefix),
                      let uuid = SidecarKey.parseGuessWhoContactURL(url.value)
                else { return false }
                return !keptUUIDs.insert(uuid).inserted
            }
        }

        switch uniqueValidUUIDs.count {
        case 0:
            return try handleCaseA(contact: &contact, malformedURLs: malformedURLs)
        case 1 where malformedURLs.isEmpty && !hadDuplicateUUID:
            return ContactReconcileResult(
                report: IdentityReconcileReport.ContactOutcome(
                    localID: contact.localID,
                    assignedUUID: nil,
                    mergedLoserUUIDs: [],
                    removedMalformedURLs: [],
                    errors: []
                ),
                carriedUUIDs: uniqueValidUUIDs
            )
        case 1 where malformedURLs.isEmpty:
            // Duplicate URL entries collapsed; persist the trimmed contact, no other changes.
            try contacts.save(contact)
            return ContactReconcileResult(
                report: IdentityReconcileReport.ContactOutcome(
                    localID: contact.localID,
                    assignedUUID: nil,
                    mergedLoserUUIDs: [],
                    removedMalformedURLs: [],
                    errors: []
                ),
                carriedUUIDs: uniqueValidUUIDs
            )
        case 1:
            return try handleCaseC(contact: &contact, validUUID: uniqueValidUUIDs[0], malformedURLs: malformedURLs)
        default:
            return try handleCaseD(contact: &contact, validUUIDs: uniqueValidUUIDs, malformedURLs: malformedURLs)
        }
    }

    private func handleCaseA(
        contact: inout Contact,
        malformedURLs: [String]
    ) throws -> ContactReconcileResult {
        contact.urlAddresses.removeAll { url in
            url.value.hasPrefix(SidecarKey.guessWhoContactURLPrefix)
                && SidecarKey.parseGuessWhoContactURL(url.value) == nil
        }
        let newUUID = UUID().uuidString.lowercased()
        contact.urlAddresses.append(
            LabeledValue(label: "GuessWho", value: SidecarKey.guessWhoContactURLPrefix + newUUID)
        )
        try contacts.save(contact)

        return ContactReconcileResult(
            report: IdentityReconcileReport.ContactOutcome(
                localID: contact.localID,
                assignedUUID: newUUID,
                mergedLoserUUIDs: [],
                removedMalformedURLs: malformedURLs,
                errors: []
            ),
            carriedUUIDs: [newUUID]
        )
    }

    private func handleCaseC(
        contact: inout Contact,
        validUUID: String,
        malformedURLs: [String]
    ) throws -> ContactReconcileResult {
        contact.urlAddresses.removeAll { url in
            url.value.hasPrefix(SidecarKey.guessWhoContactURLPrefix)
                && SidecarKey.parseGuessWhoContactURL(url.value) == nil
        }
        try contacts.save(contact)

        return ContactReconcileResult(
            report: IdentityReconcileReport.ContactOutcome(
                localID: contact.localID,
                assignedUUID: nil,
                mergedLoserUUIDs: [],
                removedMalformedURLs: malformedURLs,
                errors: []
            ),
            carriedUUIDs: [validUUID]
        )
    }

    private func handleCaseD(
        contact: inout Contact,
        validUUIDs: [String],
        malformedURLs: [String]
    ) throws -> ContactReconcileResult {
        let sortedUUIDs = validUUIDs.sorted()
        let winner = sortedUUIDs[0]
        let losers = Array(sortedUUIDs.dropFirst())

        let winnerKey = SidecarKey(kind: .contact, id: winner)

        // Acquire per-key sidecar locks for the winner and every loser in
        // deterministic sorted UUID order. Without this, a concurrent setField
        // could land on a loser between our read and delete and be silently
        // lost. Sorted-order acquisition is the deadlock-avoidance contract
        // shared with setField/deleteField (which only ever take one lock) and
        // with other reconcile passes.
        var mergedLoserUUIDs: [String] = []
        var errors: [String] = []
        let merged = try withCaseDLocks(uuidsInSortedOrder: sortedUUIDs) { () throws -> SidecarEnvelope in
            var folded = try sidecars.read(winnerKey)
                ?? SidecarEnvelope(entityID: winner, fields: [:])

            for loser in losers {
                let loserKey = SidecarKey(kind: .contact, id: loser)
                guard let loserEnvelope = try sidecars.read(loserKey) else { continue }
                let rebased = SidecarEnvelope(
                    schemaVersion: loserEnvelope.schemaVersion,
                    entityID: winner,
                    fields: loserEnvelope.fields
                )
                switch merge(folded, rebased) {
                case .success(let next):
                    folded = next
                    mergedLoserUUIDs.append(loser)
                case .failure(let err):
                    errors.append("merge failed for loser \(loser): \(err)")
                }
            }

            try sidecars.write(folded, at: winnerKey)
            for loser in losers {
                try sidecars.delete(SidecarKey(kind: .contact, id: loser))
            }
            return folded
        }
        _ = merged

        // Remove loser URLs by comparing their parsed CANONICAL UUID — string
        // comparison alone misses mixed-case copies of the same UUID. Malformed
        // GuessWho URLs are also dropped per spec.
        let loserUUIDs = Set(losers)
        contact.urlAddresses.removeAll { url in
            guard url.value.hasPrefix(SidecarKey.guessWhoContactURLPrefix) else { return false }
            guard let parsed = SidecarKey.parseGuessWhoContactURL(url.value) else { return true }
            return loserUUIDs.contains(parsed)
        }
        try contacts.save(contact)

        // §13.4 — rewrite any link endpoints pointing at a loser UUID to the
        // winner UUID. Runs after winner/loser sidecars are reconciled and
        // saved so the link graph reflects the merged state on return.
        let rewrittenLinkIDs = try rewriteLinkEndpoints(losers: losers, winner: winner)

        return ContactReconcileResult(
            report: IdentityReconcileReport.ContactOutcome(
                localID: contact.localID,
                assignedUUID: nil,
                mergedLoserUUIDs: mergedLoserUUIDs,
                removedMalformedURLs: malformedURLs,
                rewrittenLinkIDs: rewrittenLinkIDs,
                errors: errors
            ),
            carriedUUIDs: [winner]
        )
    }

    // §13.4 endpoint rewrite. For every `.link` envelope whose endpointA
    // and/or endpointB cell points at `(.contact, L)` for any `L` in
    // `losers`, write a new envelope with the affected endpoint cell(s)
    // rewritten to `(.contact, winner)`. One envelope write per affected
    // link, even when both endpoints change.
    private func rewriteLinkEndpoints(losers: [String], winner: String) throws -> [UUID] {
        guard !losers.isEmpty else { return [] }
        let loserSet = Set(losers)

        var rewritten: [UUID] = []
        for key in try sidecars.allKeys() where key.kind == .link {
            guard let envelope = try sidecars.read(key) else { continue }
            guard let aCell = envelope.fields[Link.endpointAKey],
                  let bCell = envelope.fields[Link.endpointBKey] else { continue }
            let aEndpoint = Link.decodeEndpoint(aCell.value)
            let bEndpoint = Link.decodeEndpoint(bCell.value)

            let aMatches = aEndpoint.map { $0.kind == .contact && loserSet.contains($0.id) } ?? false
            let bMatches = bEndpoint.map { $0.kind == .contact && loserSet.contains($0.id) } ?? false
            guard aMatches || bMatches else { continue }

            let now = Date()
            var fields = envelope.fields
            if aMatches {
                fields[Link.endpointAKey] = SidecarCell(
                    value: Link.encodeEndpoint(SidecarKey(kind: .contact, id: winner)),
                    modifiedAt: now,
                    modifiedBy: deviceID
                )
            }
            if bMatches {
                fields[Link.endpointBKey] = SidecarCell(
                    value: Link.encodeEndpoint(SidecarKey(kind: .contact, id: winner)),
                    modifiedAt: now,
                    modifiedBy: deviceID
                )
            }
            try sidecars.write(
                SidecarEnvelope(schemaVersion: 1, entityID: envelope.entityID, fields: fields),
                at: key
            )
            if let linkID = UUID(uuidString: key.id) {
                rewritten.append(linkID)
            }
        }
        return rewritten
    }

    // Recursively acquire per-key locks in sorted UUID order, then execute
    // body() inside the innermost lock. Sorted-order acquisition is what
    // prevents deadlock between concurrent reconcile passes (or against
    // setField, which only takes one lock).
    private func withCaseDLocks<T>(
        uuidsInSortedOrder uuids: [String],
        _ body: () throws -> T
    ) throws -> T {
        try acquireLocks(uuidsInSortedOrder: uuids, index: 0, body: body)
    }

    private func acquireLocks<T>(
        uuidsInSortedOrder uuids: [String],
        index: Int,
        body: () throws -> T
    ) throws -> T {
        if index == uuids.count {
            return try body()
        }
        let key = SidecarKey(kind: .contact, id: uuids[index])
        return try sidecarLocks.withLock(forKey: key) {
            try acquireLocks(uuidsInSortedOrder: uuids, index: index + 1, body: body)
        }
    }
}

private enum ParseOutcome {
    case ok(SidecarEnvelope)
    case skip(String)
}

private func parseEnvelope(_ data: Data) -> ParseOutcome {
    let envelope: SidecarEnvelope
    do {
        envelope = try JSONDecoder().decode(SidecarEnvelope.self, from: data)
    } catch {
        return .skip("bad JSON: \(error)")
    }
    guard envelope.schemaVersion == 1 else {
        return .skip("schemaVersion=\(envelope.schemaVersion)")
    }
    return .ok(envelope)
}
