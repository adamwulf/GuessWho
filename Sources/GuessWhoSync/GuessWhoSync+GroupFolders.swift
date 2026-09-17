import Foundation

// Storage for group folders and group placement (`plans/group-folders.md`).
//
// This layer reads and writes the reserved hierarchy cells and nothing more. It
// knows nothing about the TREE: whether a destination exists, whether a move
// closes a cycle, and where a deleted folder's children land are decided by the
// tree projection and the repository commands built on top of it. The one
// structural check made here is the one that needs no other record: a folder
// can never be its own parent.
extension GuessWhoSync {
    // MARK: - Read

    /// Every folder and every group placement, read in one corpus pass.
    ///
    /// Never throws for ONE bad record — that would let a single corrupt or
    /// not-yet-downloaded file blank the whole tree. A key whose data cannot be
    /// trusted lands in `unavailableKeys`; a key whose read failed transiently
    /// lands in `unreadableKeys`, which marks the snapshot incomplete. It
    /// throws only when the corpus cannot be enumerated at all.
    public func groupHierarchyRecords() throws -> GroupHierarchyRecords {
        var records = GroupHierarchyRecords()
        try walkSidecarCorpus(kinds: [.group, .groupFolder]) { key, result in
            let envelope: SidecarEnvelope
            switch result {
            case .success(nil):
                return
            case .success(let found?):
                envelope = found
            case .failure(let error):
                if error is DecodingError {
                    // The bytes were read and are not an envelope. Waiting will
                    // not change that: untrustworthy data, not missing data.
                    records.unavailableKeys.insert(key)
                } else {
                    // Not downloaded yet, timed out, or an I/O failure: the
                    // bytes could not be had right now, so the content is
                    // unknown and the snapshot is incomplete.
                    records.unreadableKeys.insert(key)
                }
                return
            }
            guard envelope.cellsDroppedOnDecode == 0 else {
                records.unavailableKeys.insert(key)
                return
            }
            switch key.kind {
            case .groupFolder:
                if let folder = try? GroupHierarchyCells.decodeFolder(envelope, key: key) {
                    records.folders.append(folder)
                } else {
                    records.unavailableKeys.insert(key)
                }
            case .group:
                switch GroupHierarchyCells.decodePlacement(in: envelope) {
                case .absent: break
                case .value(let placement): records.groupPlacements[key.id] = placement
                case .malformed: records.unavailableKeys.insert(key)
                }
            case .contact, .event, .link, .guide, .place:
                break
            }
        }
        return records
    }

    /// Async overload that hops the corpus pass to a background queue, like
    /// `allContactTimestamps()`: it scales with the number of groups and
    /// folders and must not block the caller's actor.
    public func groupHierarchyRecords() async throws -> GroupHierarchyRecords {
        try await withCheckedThrowingContinuation { [self] continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result: GroupHierarchyRecords = try self.groupHierarchyRecords()
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// The folder stored under `id`, or nil when there is none. Throws
    /// `lossyEnvelope` / `recordUnavailable` when it exists but cannot be
    /// trusted.
    public func groupFolderRecord(id: String) throws -> GroupFolderRecord? {
        let key = try Self.folderKey(id)
        guard let envelope = try sidecars.read(key) else { return nil }
        try Self.requireLossless(envelope, at: key)
        return try GroupHierarchyCells.decodeFolder(envelope, key: key)
    }

    /// The stored parent assignment of the group identity `identityID`, or nil
    /// when it has none (or no such identity exists).
    public func groupPlacement(identityID: String) throws -> FolderPlacement? {
        let key = SidecarKey(kind: .group, id: identityID)
        guard let envelope = try sidecars.read(key) else { return nil }
        try Self.requireLossless(envelope, at: key)
        switch GroupHierarchyCells.decodePlacement(in: envelope) {
        case .absent: return nil
        case .value(let placement): return placement
        case .malformed: throw GroupHierarchyError.recordUnavailable(key)
        }
    }

    // MARK: - Write: folders

    /// Create a folder, writing its name and its initial parent in ONE
    /// envelope so no peer can ever observe a nameless folder. A nil parent
    /// writes no `parentFolder` cell: a missing placement already means top
    /// level.
    ///
    /// `id` makes the create idempotent. Calling again with an id that already
    /// exists writes nothing and returns the folder that is there, so a caller
    /// that retries a create cannot leave two folders behind.
    @discardableResult
    public func createGroupFolder(
        name rawName: String,
        parentFolderID rawParent: String?,
        id: UUID = UUID(),
        operationID: UUID = UUID(),
        now: Date = Date()
    ) throws -> GroupFolderRecord {
        guard let name = GroupHierarchyCells.canonicalName(rawName) else {
            throw GroupHierarchyError.invalidName
        }
        let key = SidecarKey(kind: .groupFolder, id: id.uuidString)
        let parent = try Self.canonicalParent(rawParent, ofFolder: key.id)
        return try withKeyLocked(key) { ctx in
            if let existing = try ctx.read() {
                try Self.requireLossless(existing, at: key)
                return try GroupHierarchyCells.decodeFolder(existing, key: key)
            }
            let token = GroupHierarchyCells.writerToken(deviceID: deviceID, operationID: operationID)
            let stamp = try GroupHierarchyCells.stamp(laterThan: [], now: now)
            var fields: [String: SidecarCell] = [
                GroupHierarchyCells.folderNameKey: SidecarCell(
                    value: GroupHierarchyCells.nameValue(name, createdAt: stamp),
                    modifiedAt: stamp, modifiedBy: token)
            ]
            if let parent {
                fields[GroupHierarchyCells.parentFolderKey] = SidecarCell(
                    value: GroupHierarchyCells.placementValue(parentFolderID: parent, createdAt: stamp),
                    modifiedAt: stamp, modifiedBy: token)
            }
            let envelope = SidecarEnvelope(entityID: key.id, fields: fields)
            try ctx.write(envelope)
            return try GroupHierarchyCells.decodeFolder(envelope, key: key)
        }
    }

    /// Rename a folder. Changes the name cell only — never the placement.
    /// Returns whether anything was written (false for an unchanged name or a
    /// retry that already landed).
    @discardableResult
    public func renameGroupFolder(
        id: String,
        to rawName: String,
        operationID: UUID = UUID(),
        now: Date = Date()
    ) throws -> Bool {
        guard let name = GroupHierarchyCells.canonicalName(rawName) else {
            throw GroupHierarchyError.invalidName
        }
        let key = try Self.folderKey(id)
        return try withKeyLocked(key) { ctx in
            let (envelope, folder) = try Self.liveFolder(try ctx.read(), at: key)
            let cellKey = GroupHierarchyCells.folderNameKey
            let token = GroupHierarchyCells.writerToken(deviceID: deviceID, operationID: operationID)
            let existing = envelope.fields[cellKey]
            guard existing?.modifiedBy != token, folder.name != name else { return false }
            let stamp = try GroupHierarchyCells.stamp(
                laterThan: existing.map { [$0.modifiedAt] } ?? [], now: now)
            try Self.write(
                SidecarCell(
                    value: GroupHierarchyCells.nameValue(
                        name, createdAt: GroupHierarchyCells.createdAt(of: existing) ?? stamp),
                    modifiedAt: stamp, modifiedBy: token),
                as: cellKey, into: envelope, through: ctx)
            return true
        }
    }

    /// Set a folder's parent (nil = top level). Returns whether anything was
    /// written. Validating the destination against the tree is the caller's
    /// job; see the file header.
    @discardableResult
    public func setGroupFolderParent(
        id: String,
        parentFolderID rawParent: String?,
        operationID: UUID = UUID(),
        now: Date = Date()
    ) throws -> Bool {
        let key = try Self.folderKey(id)
        let parent = try Self.canonicalParent(rawParent, ofFolder: key.id)
        return try withKeyLocked(key) { ctx in
            let (envelope, folder) = try Self.liveFolder(try ctx.read(), at: key)
            return try writePlacement(
                parent, current: folder.placement, into: envelope, observed: [],
                operationID: operationID, now: now, through: ctx)
        }
    }

    /// Delete a folder by writing its deletion marker, which records where its
    /// contents were promoted to. Deletes the CONTAINER only: no child is
    /// rewritten, and groups and contacts are untouched. Returns whether
    /// anything was written — a folder that is already deleted keeps its
    /// marker, so a second delete is a no-op.
    @discardableResult
    public func markGroupFolderDeleted(
        id: String,
        promotedToFolderID rawPromotedTo: String?,
        operationID: UUID = UUID(),
        now: Date = Date()
    ) throws -> Bool {
        let key = try Self.folderKey(id)
        let promotedTo = try Self.canonicalParent(rawPromotedTo, ofFolder: key.id)
        return try withKeyLocked(key) { ctx in
            guard let envelope = try ctx.read() else {
                throw GroupHierarchyError.folderNotFound(key.id)
            }
            try Self.requireLossless(envelope, at: key)
            let folder = try GroupHierarchyCells.decodeFolder(envelope, key: key)
            guard !folder.isDeleted else { return false }
            let token = GroupHierarchyCells.writerToken(deviceID: deviceID, operationID: operationID)
            // Later than the folder's own placement: the marker is the last
            // word on where this folder's contents belong.
            let stamp = try GroupHierarchyCells.stamp(
                laterThan: folder.placement.map { [$0.modifiedAt] } ?? [], now: now)
            try Self.write(
                SidecarCell(
                    value: GroupHierarchyCells.deletionValue(
                        promotedToFolderID: promotedTo, createdAt: stamp),
                    modifiedAt: stamp, modifiedBy: token),
                as: GroupHierarchyCells.folderDeletedKey, into: envelope, through: ctx)
            return true
        }
    }

    // MARK: - Write: group placement

    /// Set the parent folder of the group identity `identityID` (nil = top
    /// level). Writes ONLY the `parentFolder` cell: the identity cell, and with
    /// it the group's resolution and its favorite, are never touched.
    ///
    /// `observed` carries the stamps of any OTHER placements the caller has
    /// seen for the same group (a duplicate identity from a cross-device race),
    /// so the new assignment is later than all of them. Returns whether
    /// anything was written.
    @discardableResult
    public func setGroupPlacement(
        identityID: String,
        parentFolderID rawParent: String?,
        observed: [Date] = [],
        operationID: UUID = UUID(),
        now: Date = Date()
    ) throws -> Bool {
        let key = SidecarKey(kind: .group, id: identityID)
        let parent = try rawParent.map { raw -> String in
            guard let id = GroupHierarchyCells.canonicalFolderID(raw) else {
                throw GroupHierarchyError.invalidFolderID(raw)
            }
            return id
        }
        return try withKeyLocked(key) { ctx in
            guard let envelope = try ctx.read() else {
                throw GroupHierarchyError.identityNotFound(key.id)
            }
            try Self.requireLossless(envelope, at: key)
            let current: FolderPlacement?
            switch GroupHierarchyCells.decodePlacement(in: envelope) {
            case .absent: current = nil
            case .value(let placement): current = placement
            case .malformed: throw GroupHierarchyError.recordUnavailable(key)
            }
            return try writePlacement(
                parent, current: current, into: envelope, observed: observed,
                operationID: operationID, now: now, through: ctx)
        }
    }

    // MARK: - Shared

    /// Refuse to write through an envelope that decoded with dropped cells. See
    /// `GroupHierarchyError.lossyEnvelope`. `internal` so `writeGroupIdentity`
    /// applies the same rule to the identity cell that shares the envelope.
    static func requireLossless(_ envelope: SidecarEnvelope?, at key: SidecarKey) throws {
        guard let envelope, envelope.cellsDroppedOnDecode > 0 else { return }
        throw GroupHierarchyError.lossyEnvelope(key)
    }

    private static func folderKey(_ rawID: String) throws -> SidecarKey {
        guard let id = GroupHierarchyCells.canonicalFolderID(rawID) else {
            throw GroupHierarchyError.invalidFolderID(rawID)
        }
        return SidecarKey(kind: .groupFolder, id: id)
    }

    /// `rawParent` in canonical form. A folder naming ITSELF is refused here
    /// because it needs no other record to detect; longer cycles are the tree's
    /// to catch.
    private static func canonicalParent(_ rawParent: String?, ofFolder folderID: String) throws -> String? {
        guard let rawParent else { return nil }
        guard let parent = GroupHierarchyCells.canonicalFolderID(rawParent) else {
            throw GroupHierarchyError.invalidFolderID(rawParent)
        }
        guard parent != folderID else { throw GroupHierarchyError.wouldCreateCycle }
        return parent
    }

    /// The envelope and decoded folder at `key`, required to exist, be
    /// trustworthy, and not be deleted.
    private static func liveFolder(
        _ envelope: SidecarEnvelope?, at key: SidecarKey
    ) throws -> (SidecarEnvelope, GroupFolderRecord) {
        guard let envelope else { throw GroupHierarchyError.folderNotFound(key.id) }
        try requireLossless(envelope, at: key)
        let folder = try GroupHierarchyCells.decodeFolder(envelope, key: key)
        guard !folder.isDeleted else { throw GroupHierarchyError.folderDeleted(key.id) }
        return (envelope, folder)
    }

    /// Write a `parentFolder` cell into `envelope` unless it would change
    /// nothing: the stored assignment already names `parent` (a missing cell
    /// and a nil parent both mean top level), or this exact logical write
    /// already landed. Clearing a parent writes a newer NULL — the cell is
    /// never removed, because an absent cell cannot beat an older assignment
    /// that syncs in later.
    private func writePlacement(
        _ parent: String?,
        current: FolderPlacement?,
        into envelope: SidecarEnvelope,
        observed: [Date],
        operationID: UUID,
        now: Date,
        through ctx: KeyLockedContext
    ) throws -> Bool {
        let cellKey = GroupHierarchyCells.parentFolderKey
        let token = GroupHierarchyCells.writerToken(deviceID: deviceID, operationID: operationID)
        guard current?.modifiedBy != token, current?.parentFolderID != parent else { return false }
        let stamp = try GroupHierarchyCells.stamp(
            laterThan: observed + (current.map { [$0.modifiedAt] } ?? []), now: now)
        let createdAt = GroupHierarchyCells.createdAt(of: envelope.fields[cellKey]) ?? stamp
        try Self.write(
            SidecarCell(
                value: GroupHierarchyCells.placementValue(parentFolderID: parent, createdAt: createdAt),
                modifiedAt: stamp, modifiedBy: token),
            as: cellKey, into: envelope, through: ctx)
        return true
    }

    /// Replace ONE cell and write the whole raw cell map back, so every other
    /// cell — including ones this build cannot decode — rides along untouched
    /// (`docs/sidecar-compatibility.md`).
    private static func write(
        _ cell: SidecarCell,
        as cellKey: String,
        into envelope: SidecarEnvelope,
        through ctx: KeyLockedContext
    ) throws {
        var fields = envelope.fields
        fields[cellKey] = cell
        try ctx.write(SidecarEnvelope(
            schemaVersion: envelope.schemaVersion, entityID: envelope.entityID, fields: fields))
    }
}
