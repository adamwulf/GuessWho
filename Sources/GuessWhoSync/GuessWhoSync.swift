import Foundation
import Logging

// Thread-safety is provided by `sidecarLocks` (per-sidecar serialization
// for read-modify-write) and by the fact that `contacts` is now an actor.
// Conformers passed in for `events` / `sidecars` are expected to handle
// their own internal locking (the bundled FileSystemSidecarStore and
// InMemorySidecarStore both do). Marked @unchecked so the type can be
// shared across actors without requiring those protocols to be Sendable.
public final class GuessWhoSync: @unchecked Sendable {
    /// Same label as the adapter/repository save breadcrumbs: every CNContact
    /// write REQUEST logs its initiating operation so a failed save in the log
    /// is attributable (the reconcile writes here were previously silent).
    private static let saveLog = Logger(label: "sync.contact-save")

    private let contacts: ContactStoreProtocol
    internal let events: EventStoreProtocol
    internal let sidecars: SidecarStoreProtocol
    internal let deviceID: String
    internal let sidecarLocks = PerKeyLockTable<SidecarKey>()

    /// Device-local persistence for the external-contact-change cursor. Present
    /// only when a host wants this instance to own the change watcher; `nil`
    /// disables `startContactChangeWatcher()` (it becomes a no-op). Tests and
    /// non-UI contexts pass `nil` so nothing observes by default.
    private let contactCursorStore: ContactSyncCursorStore?

    /// The package-owned external-contact-change watcher. Created lazily by
    /// `startContactChangeWatcher()` and held for the instance's lifetime so the
    /// `.CNContactStoreDidChange` registration stays alive. Touched ONLY from the
    /// `@MainActor` start/stop methods, which is what makes the unchecked
    /// isolation safe.
    private nonisolated(unsafe) var contactChangeWatcher: ContactChangeWatcher?

    public init(
        contacts: ContactStoreProtocol,
        events: EventStoreProtocol,
        sidecars: SidecarStoreProtocol,
        deviceID: String,
        contactCursorStore: ContactSyncCursorStore? = nil
    ) {
        self.contacts = contacts
        self.events = events
        self.sidecars = sidecars
        self.deviceID = deviceID
        self.contactCursorStore = contactCursorStore
    }

    // MARK: - Per-key atomicity

    /// The handle through which a key's sidecar envelope and its `.blob` `.dat`
    /// neighbors are touched for a COMPOUND op. An instance exists only inside a
    /// `withKeyLocked(_:)` body — i.e. only while this `GuessWhoSync` holds the
    /// key's `sidecarLocks` lock — so every read-modify-write (read envelope →
    /// write envelope; read envelope → read `.dat`; repoint pointer → delete
    /// superseded `.dat`) is atomic against any other op on the same key. Since a
    /// compound op cannot reach `read`/`write`/`*Blob` for a key without first
    /// being inside its lock, the two blob races we hit are unrepresentable.
    ///
    /// Deliberate carve-outs (NOT bugs):
    ///   - Single-call PURE READS (`field`/`fields`/`link`/`links`, the sweep's
    ///     global harvest) call `sidecars.read` directly without locking: one
    ///     `read(key)` is atomic on its own, so a lock would only add contention.
    ///   - MULTI-KEY ops (identity-reconcile's winner/loser fold via
    ///     `acquireLocks`, and the SPI `reconcileConflict`) lock several keys /
    ///     use a different store API and so can't use this single-key context.
    ///
    /// Non-`Sendable` and non-escaping: the context must not outlive the locked
    /// block (it would reference the store outside the lock). The lock is
    /// per-key, so unrelated contacts/events still run fully in parallel.
    struct KeyLockedContext {
        let key: SidecarKey
        fileprivate let sidecars: SidecarStoreProtocol

        func read() throws -> SidecarEnvelope? { try sidecars.read(key) }
        func write(_ envelope: SidecarEnvelope) throws { try sidecars.write(envelope, at: key) }
        func writeBlob(_ data: Data, blobId: String) throws { try sidecars.writeBlob(data, blobId: blobId, for: key) }
        func readBlob(blobId: String) throws -> Data? { try sidecars.readBlob(blobId: blobId, for: key) }
        func deleteBlob(blobId: String) throws { try sidecars.deleteBlob(blobId: blobId, for: key) }
        func blobIds() throws -> [String] { try sidecars.blobIds(for: key) }
    }

    /// Run `body` holding `key`'s per-key lock, handing it the one
    /// `KeyLockedContext` through which the key's envelope + blobs are reachable.
    /// Every op that touches a key's sidecar data MUST go through here so the
    /// compound op is atomic against concurrent ops on the same key. Do NOT nest
    /// `withKeyLocked` for the SAME key inside a body — the underlying lock is
    /// non-reentrant (`PerKeyLockTable` uses a plain `NSLock`); a body needing a
    /// second key locks that other key, never the one it already holds.
    @discardableResult
    func withKeyLocked<T>(_ key: SidecarKey, _ body: (KeyLockedContext) throws -> T) rethrows -> T {
        try sidecarLocks.withLock(forKey: key) {
            try body(KeyLockedContext(key: key, sidecars: sidecars))
        }
    }

    // MARK: - External contact-change watcher

    /// Start observing external contact-store changes and posting
    /// `.guessWhoContactsDidChange`. Opt-in: a no-op unless this instance was
    /// constructed with a `contactCursorStore`. Idempotent. Call once at launch,
    /// after the app's initial reload, so the watcher picks up subsequent edits
    /// made in Contacts.app / on another device.
    @MainActor
    public func startContactChangeWatcher() {
        guard let contactCursorStore else { return }
        if contactChangeWatcher == nil {
            contactChangeWatcher = ContactChangeWatcher(
                contacts: contacts,
                cursorStore: contactCursorStore
            )
        }
        contactChangeWatcher?.start()
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
    /// minted UUID. `createdAt` defaults to now; callers may back- or
    /// forward-date it (notes surface it as the user-editable note date).
    /// The cell's `modifiedAt` stamp is always the actual write time.
    @discardableResult
    public func addField(
        at key: SidecarKey,
        field: String,
        type: SidecarFieldType,
        value: JSONValue,
        createdAt: Date = Date()
    ) throws -> UUID {
        try SidecarField.validate(value: value, against: type)
        return try withKeyLocked(key) { ctx in
            let existing = try ctx.read()
            let id = UUID()
            let now = Date()
            let inner = SidecarField.makeInnerValue(
                field: field,
                type: type,
                value: value,
                createdAt: createdAt
            )
            let cell = SidecarCell(value: inner, modifiedAt: now, modifiedBy: deviceID)
            var fields = existing?.fields ?? [:]
            fields[id.uuidString] = cell
            let envelope = SidecarEnvelope(
                schemaVersion: 1,
                entityID: existing?.entityID ?? key.id,
                fields: fields
            )
            try ctx.write(envelope)
            return id
        }
    }

    /// Mutates an existing field instance's caller-supplied name and/or
    /// value. Reads the existing cell to recover the immutable `type`;
    /// throws `typeValueMismatch` if the new value doesn't match. Bumps
    /// `modifiedAt`/`modifiedBy` and clears `deletedAt` (undelete: writing
    /// to a soft-deleted cell brings it back as live). A non-nil `createdAt`
    /// re-stamps the inner `createdAt` (the user-editable date on notes);
    /// nil preserves the existing stamp. Silent no-op if the cell is
    /// missing.
    public func setField(
        at key: SidecarKey,
        id: UUID,
        field: String,
        value: JSONValue,
        createdAt: Date? = nil
    ) throws {
        try withKeyLocked(key) { ctx in
            guard let existing = try ctx.read(),
                  let existingCell = existing.fields[id.uuidString]
            else { return }
            guard let type = SidecarField.type(of: existingCell) else { return }
            try SidecarField.validate(value: value, against: type)

            guard let inner = SidecarField.makeInnerValueForEdit(
                existingCell: existingCell,
                newField: field,
                newValue: value,
                newCreatedAt: createdAt
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
            try ctx.write(envelope)
        }
    }

    /// Soft-deletes a field instance by setting cell `deletedAt = now`,
    /// bumping `modifiedAt`/`modifiedBy`. The inner value object is
    /// preserved as a record of what was deleted. Silent no-op if the
    /// cell is missing or already soft-deleted.
    public func deleteField(at key: SidecarKey, id: UUID) throws {
        try withKeyLocked(key) { ctx in
            guard let existing = try ctx.read(),
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
            try ctx.write(envelope)
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

    // MARK: - Blob field API (`.blob`)
    //
    // A `.blob` field is a SINGLE-SLOT pointer (by field name) to a binary
    // `.dat` payload living beside the envelope. `setBlobField` writes the
    // bytes, upserts the pointer cell, and deletes any superseded `.dat`
    // (the orphan sweep is the cross-device backstop; delete-on-overwrite is
    // the same-device fast path). A FRESH blobId is minted per write so a new
    // snapshot never collides with an in-flight older `.dat` mid-sync.

    /// Async overload of `setBlobField(at:field:data:contentType:)` that hops
    /// the write to a background queue: it AES-GCM-encrypts the full payload
    /// (photos run to megabytes), writes the sealed `.dat` under coordination,
    /// and read-modify-writes the envelope — none of which belongs on the
    /// caller's actor / main thread. Same continuation pattern as the async
    /// read overloads.
    @discardableResult
    public func setBlobField(
        at key: SidecarKey,
        field: String,
        data: Data,
        contentType: String
    ) async throws -> String {
        try await withCheckedThrowingContinuation { [self] continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result: String = try self.setBlobField(
                        at: key, field: field, data: data, contentType: contentType
                    )
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Upsert a single-slot `.blob` field named `field` on `key`, storing
    /// `data` as a fresh `.dat` and pointing the field at it. If a live `.blob`
    /// field with the same name already exists, its pointer is repointed to the
    /// new blobId and the OLD `.dat` is deleted (fast-path reclaim). Returns the
    /// new blobId. Throws `typeValueMismatch` if a same-named field of a
    /// different type already exists (a `.blob` slot can't overwrite a `.note`).
    @discardableResult
    public func setBlobField(
        at key: SidecarKey,
        field: String,
        data: Data,
        contentType: String
    ) throws -> String {
        let newBlobId = UUID().uuidString.lowercased()
        let pointer = BlobPointer(
            blobId: newBlobId,
            contentType: contentType,
            byteCount: data.count
        ).jsonValue

        // Capture the superseded blobId (if any) to delete after the envelope
        // write commits the repoint.
        var supersededBlobId: String?
        try withKeyLocked(key) { ctx in
            // Write the bytes FIRST, but INSIDE the per-key lock (the only way to
            // reach `ctx.writeBlob`): the orphan sweep re-reads this key's
            // envelope under the same lock, so committing the `.dat` and the
            // pointer atomically w.r.t. the lock closes the window where a
            // concurrent sweep would see the fresh `.dat` on disk, find it
            // unreferenced (the repoint hasn't landed), and delete it as a false
            // orphan. Writing the `.dat` before the envelope means a mid-failure
            // leaves an orphan (swept later), never a dangling pointer.
            try ctx.writeBlob(data, blobId: newBlobId)

            let existing = try ctx.read()
            var fields = existing?.fields ?? [:]
            let now = Date()

            // Find a live same-named `.blob` cell to repoint (single slot).
            let slot = fields.first { (_, cell) in
                cell.deletedAt == nil
                    && SidecarField.type(of: cell) == .blob
                    && {
                        if case .object(let inner) = cell.value,
                           case .string(let name) = inner[SidecarField.innerFieldKey] ?? .null {
                            return name == field
                        }
                        return false
                    }()
            }

            if let (slotID, slotCell) = slot {
                // Repoint the existing slot, preserving its type/createdAt.
                if case .object(let inner) = slotCell.value,
                   case .object(let oldPointer) = inner[SidecarField.innerValueKey] ?? .null,
                   case .string(let oldBlobId) = oldPointer[BlobPointer.blobIdKey] ?? .null,
                   oldBlobId != newBlobId {
                    supersededBlobId = oldBlobId
                }
                guard let newInner = SidecarField.makeInnerValueForEdit(
                    existingCell: slotCell,
                    newField: field,
                    newValue: pointer
                ) else { return }
                fields[slotID] = SidecarCell(
                    value: newInner,
                    modifiedAt: now,
                    modifiedBy: deviceID,
                    deletedAt: nil
                )
            } else {
                // No existing slot — but a same-named field of ANOTHER type is
                // a caller error (a `.blob` slot can't silently replace it).
                let conflicting = fields.contains { (_, cell) in
                    cell.deletedAt == nil
                        && SidecarField.type(of: cell) != .blob
                        && {
                            if case .object(let inner) = cell.value,
                               case .string(let name) = inner[SidecarField.innerFieldKey] ?? .null {
                                return name == field
                            }
                            return false
                        }()
                }
                if conflicting {
                    throw SidecarStoreError.typeValueMismatch(expected: .blob, got: pointer)
                }
                let id = UUID()
                let inner = SidecarField.makeInnerValue(
                    field: field,
                    type: .blob,
                    value: pointer,
                    createdAt: now
                )
                fields[id.uuidString] = SidecarCell(value: inner, modifiedAt: now, modifiedBy: deviceID)
            }

            let envelope = SidecarEnvelope(
                schemaVersion: 1,
                entityID: existing?.entityID ?? key.id,
                fields: fields
            )
            try ctx.write(envelope)

            // Delete-on-overwrite fast path, INSIDE the lock: drop the superseded
            // `.dat` atomically with the repoint so a concurrent reader holding
            // this same per-key lock never captures a pointer to a blobId about
            // to be deleted out from under its `readBlob` (the read↔overwrite
            // race). A failure is non-fatal and not propagated — the orphan sweep
            // reclaims it later.
            if let supersededBlobId {
                try? ctx.deleteBlob(blobId: supersededBlobId)
            }
        }

        return newBlobId
    }

    /// Read the bytes a single-slot `.blob` field named `field` on `key`
    /// points at, or nil when there is no such live field OR its `.dat` is not
    /// materialized on this device yet (a missing/pending payload is benign).
    ///
    /// The envelope-pointer read and the blob-bytes read run under the per-key
    /// lock TOGETHER: a concurrent `setBlobField` overwrite deletes the
    /// superseded `.dat` under that same lock, so holding it here makes
    /// capture+read atomic against the overwrite. Without it, a reader could
    /// capture the old pointer and then have `readBlob` miss the `.dat` the
    /// overwrite deleted in between (the read↔overwrite race).
    public func blobFieldData(at key: SidecarKey, field: String) throws -> Data? {
        try withKeyLocked(key) { ctx in
            guard let envelope = try ctx.read() else { return nil }
            for (rawID, cell) in envelope.fields {
                guard cell.deletedAt == nil,
                      let id = UUID(uuidString: rawID),
                      let decoded = SidecarField.decode(id: id, from: cell),
                      decoded.type == .blob,
                      decoded.field == field,
                      let pointer = BlobPointer(from: decoded.value)
                else { continue }
                return try ctx.readBlob(blobId: pointer.blobId)
            }
            return nil
        }
    }

    // MARK: - Orphan blob sweep
    //
    // The envelope merge is whole-cell LWW, so a cross-device race — two
    // devices each snapshot a DIFFERENT previous photo into the same single-slot
    // `.blob` field — keeps one cell and silently drops the loser's pointer,
    // leaving the loser's `.dat` on disk unreferenced. Delete-on-overwrite (in
    // setBlobField) is the same-device fast path; this reference-counting sweep
    // is the cross-device backstop.

    /// Delete every `.dat` whose blobId is referenced by NO live (non-soft-
    /// deleted) `.blob` field across ALL keys.
    ///
    /// Conservative by construction: the referenced-blob set is built from
    /// every readable envelope. If ANY envelope read fails this pass (e.g. a
    /// not-yet-downloaded `.json`), a referenced blob might hide in that
    /// unreadable envelope, so NO deletions happen — `deletionSkipped` is true
    /// and the next pass retries once envelopes are readable. A blob whose
    /// envelope IS readable but whose `.dat` simply hasn't downloaded is
    /// "pending," not orphan, and is never deleted (it isn't on disk to list,
    /// and its pointer keeps it referenced).
    @discardableResult
    public func sweepOrphanBlobs() throws -> BlobSweepReport {
        let keys = try sidecars.allKeys()

        // 1. Build the GLOBAL set of referenced blobIds from every readable
        //    envelope. Track read failures — any failure makes the set
        //    potentially incomplete.
        var referenced = Set<String>()
        var skippedReasons: [String] = []
        var anyEnvelopeUnreadable = false
        for key in keys {
            do {
                guard let envelope = try sidecars.read(key) else { continue }
                for (_, cell) in envelope.fields {
                    guard cell.deletedAt == nil,
                          SidecarField.type(of: cell) == .blob,
                          case .object(let inner) = cell.value,
                          // Lenient: protect a `.dat` whenever ANY live cell
                          // names its blobId, even if the rest of the pointer
                          // is malformed — never sweep a still-referenced blob.
                          let blobId = BlobPointer.referencedBlobId(from: inner[SidecarField.innerValueKey] ?? .null)
                    else { continue }
                    referenced.insert(blobId)
                }
            } catch {
                anyEnvelopeUnreadable = true
                skippedReasons.append("envelope read failed for \(key.kind)/\(key.id): \(error)")
            }
        }

        // 2. If the reference set is incomplete, do NOT delete anything — a
        //    live pointer could be in an envelope we couldn't read.
        guard !anyEnvelopeUnreadable else {
            return BlobSweepReport(deleted: [], deletionSkipped: true, skippedReasons: skippedReasons)
        }

        // 3. Reference set is authoritative. For each key, list its `.dat`s and
        //    delete any whose blobId is unreferenced. A blob-listing failure
        //    for one key skips that key only (the others still sweep).
        //
        //    The list + per-blob decision + delete run under the key's sidecar
        //    lock, and the key's envelope is RE-READ inside the lock, so a
        //    concurrent setBlobField that landed since the snapshot isn't
        //    clobbered as a false orphan: a blob is deleted only when
        //    unreferenced by BOTH the global snapshot set AND the key's fresh
        //    envelope. (A `.dat` is only ever written under the key whose
        //    envelope references it — blobIds are minted fresh per write — so
        //    the fresh same-key envelope is the authority for newly-arrived
        //    pointers.)
        var deleted: [BlobSweepReport.Deleted] = []
        for key in keys {
            do {
                let perKeyDeleted = try withKeyLocked(key) { ctx -> [BlobSweepReport.Deleted] in
                    let onDisk = try ctx.blobIds()
                    // Fresh live blobIds referenced by THIS key's current envelope.
                    var liveHere = Set<String>()
                    if let envelope = try ctx.read() {
                        for (_, cell) in envelope.fields {
                            guard cell.deletedAt == nil,
                                  SidecarField.type(of: cell) == .blob,
                                  case .object(let inner) = cell.value,
                                  // Lenient blobId (see the global harvest above).
                                  let blobId = BlobPointer.referencedBlobId(from: inner[SidecarField.innerValueKey] ?? .null)
                            else { continue }
                            liveHere.insert(blobId)
                        }
                    }
                    var localDeleted: [BlobSweepReport.Deleted] = []
                    for blobId in onDisk where !referenced.contains(blobId) && !liveHere.contains(blobId) {
                        try ctx.deleteBlob(blobId: blobId)
                        localDeleted.append(BlobSweepReport.Deleted(key: ctx.key, blobId: blobId))
                    }
                    return localDeleted
                }
                deleted.append(contentsOf: perKeyDeleted)
            } catch {
                skippedReasons.append("blob sweep failed for \(key.kind)/\(key.id): \(error)")
                continue
            }
        }

        return BlobSweepReport(deleted: deleted, deletionSkipped: false, skippedReasons: skippedReasons)
    }

    // MARK: - Link API (§13)

    /// Creates a link between two entities. Writes one envelope and
    /// returns the minted Link. Never dedups — multiple links between
    /// the same endpoints are allowed.
    /// Note: a same-key (self) link would be counted twice by `linkCounts(ofKind:)` — once per endpoint.
    @discardableResult
    public func addLink(from a: SidecarKey, to b: SidecarKey, note: String) throws -> Link {
        let id = UUID()
        let key = SidecarKey(kind: .link, id: id.uuidString)
        let now = Date()
        // createdAt is stored as a millisecond-precision ISO8601 string.
        // Round-trip `now` through that string so the returned Link's createdAt
        // matches what link(id:) reads back.
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
        try withKeyLocked(key) { ctx in
            try ctx.write(envelope)
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
        try withKeyLocked(key) { ctx in
            guard let existing = try ctx.read() else { return }
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
            try ctx.write(
                SidecarEnvelope(schemaVersion: 1, entityID: existing.entityID, fields: fields)
            )
        }
    }

    /// Soft-deletes the link by writing the deletedAt cell with an ISO8601
    /// timestamp value. All other cells are preserved so a future
    /// setLinkNote can undelete without losing the note. Silent no-op if
    /// the link is missing or already soft-deleted.
    public func removeLink(id: UUID) throws {
        let key = SidecarKey(kind: .link, id: id.uuidString)
        try withKeyLocked(key) { ctx in
            guard let existing = try ctx.read() else { return }
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
            try ctx.write(
                SidecarEnvelope(schemaVersion: 1, entityID: existing.entityID, fields: fields)
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

    /// Async overload of `links(at:)` that hops the scan to a background
    /// queue: the read walks EVERY link sidecar (a coordinated read + decode
    /// per file), so it scales with total link count and must not block the
    /// caller's actor / main thread. Same continuation-hop pattern (and
    /// `self` capture rationale) as `recentEvents(matchingEmails:)` in the
    /// Events extension. Sync callers keep the synchronous overload.
    public func links(at endpoint: SidecarKey) async throws -> [Link] {
        try await withCheckedThrowingContinuation { [self] continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result: [Link] = try self.links(at: endpoint)
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Every distinct endpoint of `kind` that participates in at least one
    /// live (non-soft-deleted) link. This is the bulk form of `links(at:)` for
    /// list filters: one O(N links) pass can identify all linked contacts,
    /// events, or places without performing an O(N endpoints × N links) scan.
    public func linkedEndpoints(ofKind kind: SidecarKind) throws -> Set<SidecarKey> {
        var result: Set<SidecarKey> = []
        for key in try sidecars.allKeys() where key.kind == .link {
            guard let envelope = try sidecars.read(key),
                  let link = Link(from: envelope),
                  link.deletedAt == nil else { continue }
            if link.endpointA.kind == kind {
                result.insert(link.endpointA)
            }
            if link.endpointB.kind == kind {
                result.insert(link.endpointB)
            }
        }
        return result
    }

    /// Async overload of `linkedEndpoints(ofKind:)`; the complete link scan
    /// runs on a background queue so a list reload never blocks its actor.
    public func linkedEndpoints(ofKind kind: SidecarKind) async throws -> Set<SidecarKey> {
        try await withCheckedThrowingContinuation { [self] continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result = try self.linkedEndpoints(ofKind: kind)
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// For every distinct endpoint of `kind`, the number of live
    /// (non-soft-deleted) links that endpoint participates in. Bulk form for
    /// list badges: one O(N links) pass tallies all counts, mirroring
    /// `linkedEndpoints(ofKind:)` but counting rather than collecting presence.
    /// Counts ALL links touching the endpoint regardless of the far endpoint's
    /// kind, consistent with the Linked filter.
    public func linkCounts(ofKind kind: SidecarKind) throws -> [SidecarKey: Int] {
        var result: [SidecarKey: Int] = [:]
        for key in try sidecars.allKeys() where key.kind == .link {
            guard let envelope = try sidecars.read(key),
                  let link = Link(from: envelope),
                  link.deletedAt == nil else { continue }
            if link.endpointA.kind == kind {
                result[link.endpointA, default: 0] += 1
            }
            if link.endpointB.kind == kind {
                result[link.endpointB, default: 0] += 1
            }
        }
        return result
    }

    /// Async overload of `linkCounts(ofKind:)`; the complete link scan
    /// runs on a background queue so a list reload never blocks its actor.
    public func linkCounts(ofKind kind: SidecarKind) async throws -> [SidecarKey: Int] {
        try await withCheckedThrowingContinuation { [self] continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result = try self.linkCounts(ofKind: kind)
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Contact timestamp cells

    /// Upserts ONE named timestamp cell on the envelope at `key`, writing
    /// `now` as an ISO8601 string: read the existing envelope, replace just the
    /// targeted cell (other cells preserved), write back under the same
    /// `entityID`. If no envelope exists yet, mint one with `entityID = key.id`
    /// (the envelope-on-demand behavior `addField` uses for a first write).
    /// ADDITIVE and schema-stable: only the one timestamp cell changes.
    public func stampContactTimestamp(_ which: ContactTimestampKind, at key: SidecarKey, now: Date) throws {
        try withKeyLocked(key) { ctx in
            let existing = try ctx.read()
            var fields = existing?.fields ?? [:]
            fields[which.cellKey] = SidecarCell(
                value: .string(SidecarISO8601.string(from: now)),
                modifiedAt: now,
                modifiedBy: deviceID
            )
            try ctx.write(
                SidecarEnvelope(
                    schemaVersion: 1,
                    entityID: existing?.entityID ?? key.id,
                    fields: fields
                )
            )
        }
    }

    /// Reads the three timestamp cells off the envelope at `key`. Returns
    /// `ContactTimestamps(nil, nil, nil)` when the envelope is missing or
    /// carries none of the cells — a pure read, never mints.
    public func contactTimestamps(at key: SidecarKey) throws -> ContactTimestamps {
        guard let envelope = try sidecars.read(key) else { return ContactTimestamps() }
        return ContactTimestamps(from: envelope)
    }

    /// Bulk-reads the timestamps for EVERY contact sidecar, keyed by `key.id`
    /// (the lowercased GuessWho UUID). Reads only the `.contact` keys; an
    /// envelope that fails to read is skipped (no entry). O(N contacts).
    public func allContactTimestamps() throws -> [String: ContactTimestamps] {
        var result: [String: ContactTimestamps] = [:]
        for key in try sidecars.allKeys() where key.kind == .contact {
            guard let envelope = try sidecars.read(key) else { continue }
            result[key.id] = ContactTimestamps(from: envelope)
        }
        return result
    }

    /// Async overload of `allContactTimestamps()` that hops the scan to a
    /// background queue: the read walks EVERY contact sidecar (a coordinated
    /// read + decode per file), so it scales with total contact count and must
    /// not block the caller's actor / cooperative pool. Same continuation-hop
    /// pattern (and `self` capture rationale) as `links(at:)`.
    public func allContactTimestamps() async throws -> [String: ContactTimestamps] {
        try await withCheckedThrowingContinuation { [self] continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result: [String: ContactTimestamps] = try self.allContactTimestamps()
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func reconcileSidecars() throws -> SidecarReconcileReport {
        // A third-party SidecarStoreProtocol conformer with no concept of
        // multi-version conflicts has nothing to reconcile.
        guard let conflictStore = sidecars as? SidecarConflictReconciling else {
            return SidecarReconcileReport(fileOutcomes: [])
        }

        var stamped: [SidecarReconcileReport.FileOutcome] = []

        // Hold the per-key sidecarLock for the WHOLE resolver + write window
        // (resolver invocation through the store's merged-write). Otherwise a
        // concurrent setField on the same key would slip a write between the
        // store's read-versions and its merged-write and be silently clobbered.
        for key in try conflictStore.keysWithUnresolvedConflicts() {
            var reasons: [String] = []
            let outcome = try sidecarLocks.withLock(forKey: key) { () throws -> SidecarReconcileReport.FileOutcome? in
                try conflictStore.reconcileConflict(at: key) { currentBytes, conflictBytes in
                    var parseable: [SidecarEnvelope] = []
                    // §5.3 silent cell drops — sum across every parseable
                    // envelope going into the fold. Surface in skippedReasons
                    // so a peer shipping broken cells is observable.
                    var totalCellsDropped = 0
                    // EntityID guard: a parseable envelope whose entityID
                    // doesn't match the key's id is corrupt routing — it
                    // belongs to some other entity. Drop it from the fold
                    // and report; never let it propagate as the new ground
                    // truth at this key.
                    func ingest(_ env: SidecarEnvelope, label: String) {
                        guard env.entityID == key.id else {
                            reasons.append("\(label): entityID \(env.entityID) ≠ key \(key.id); dropped")
                            return
                        }
                        parseable.append(env)
                        totalCellsDropped += env.cellsDroppedOnDecode
                    }
                    if let currentBytes {
                        switch parseEnvelope(currentBytes) {
                        case .ok(let env):
                            ingest(env, label: "current")
                        case .skip(let reason):
                            reasons.append("current: \(reason)")
                        }
                    }
                    for bytes in conflictBytes {
                        switch parseEnvelope(bytes) {
                        case .ok(let env):
                            ingest(env, label: "conflict")
                        case .skip(let reason):
                            reasons.append(reason)
                        }
                    }
                    if totalCellsDropped > 0 {
                        reasons.append("dropped \(totalCellsDropped) malformed cell(s)")
                    }

                    // Fold every parseable envelope into one merged result.
                    // If nothing parsed, write an empty envelope at this key
                    // so every device still converges to the same byte state.
                    guard var folded = parseable.first else {
                        return SidecarEnvelope(entityID: key.id, fields: [:])
                    }
                    for next in parseable.dropFirst() {
                        switch merge(folded, next) {
                        case .success(let combined):
                            folded = combined
                        case .failure(let err):
                            reasons.append("merge failed: \(err)")
                        }
                    }
                    return folded
                }
            }
            if let outcome {
                stamped.append(
                    SidecarReconcileReport.FileOutcome(
                        key: outcome.key,
                        versionsConsidered: outcome.versionsConsidered,
                        skippedReasons: outcome.skippedReasons + reasons
                    )
                )
            }
        }

        return SidecarReconcileReport(fileOutcomes: stamped)
    }

    /// Async overload of `reconcileSidecars()` that runs the coordinated
    /// iCloud file-version scan off the caller's actor. Production invokes
    /// this from `SidecarFileWatcher` on the main actor, so doing the blocking
    /// `NSFileCoordinator` work there would freeze UI while cloudd is busy.
    ///
    /// Keep this as a thin hop into the synchronous implementation: tests that
    /// script conflicts in `InMemorySidecarStore` and production's
    /// `NSFileVersion` path therefore exercise exactly the same merge code.
    @discardableResult
    public func reconcileSidecars() async throws -> SidecarReconcileReport {
        try await withCheckedThrowingContinuation { [self] continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result: SidecarReconcileReport = try self.reconcileSidecars()
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func reconcileContactIdentities() async throws -> IdentityReconcileReport {
        var results: [ContactReconcileResult] = []
        var carriedUUIDs: Set<String> = []
        // Aggregate loser→winner mapping across every Case D in this pass so
        // we can rewrite each affected link envelope exactly once (§13.4).
        var loserToWinner: [String: String] = [:]
        // Per-contact list of losers, so we can attribute rewrittenLinkIDs
        // back to the contact whose Case D touched each link.
        var losersByLocalID: [String: [String]] = [:]

        for contact in try await contacts.fetchAll() {
            let result = try await reconcile(contact: contact)
            results.append(result)
            carriedUUIDs.formUnion(result.carriedUUIDs)
            for loser in result.losers {
                loserToWinner[loser] = result.winnerUUID
            }
            if !result.losers.isEmpty {
                losersByLocalID[result.report.localID, default: []].append(contentsOf: result.losers)
            }
        }

        // Run the link-endpoint rewrite once over the union of all losers from
        // every Case D in this pass — §13.4: "one envelope write per link,
        // even when both endpoints change."
        let rewrittenLinksByLoser = try rewriteLinkEndpoints(mapping: loserToWinner)

        // Attribute rewritten link IDs back to each contact's outcome. A link
        // touched by losers belonging to two different contacts appears in
        // both outcomes (§13.4).
        var outcomes: [IdentityReconcileReport.ContactOutcome] = []
        outcomes.reserveCapacity(results.count)
        for result in results {
            var rewritten: [UUID] = []
            var seen: Set<UUID> = []
            for loser in result.losers {
                guard let ids = rewrittenLinksByLoser[loser] else { continue }
                for id in ids where seen.insert(id).inserted {
                    rewritten.append(id)
                }
            }
            outcomes.append(result.report.with(rewrittenLinkIDs: rewritten))
        }

        let orphans = try sidecars.allKeys()
            .filter { $0.kind == .contact && !carriedUUIDs.contains($0.id) }
            .sorted { $0.id < $1.id }

        return IdentityReconcileReport(contactOutcomes: outcomes, orphanSidecars: orphans)
    }

    // Single-contact entry point for host apps wanting explicit per-contact
    // control. Orphan-sidecar detection is intentionally NOT performed here: it
    // needs the complete set of carried UUIDs across every contact to be
    // meaningful — use reconcileContactIdentities() when that's needed.
    //
    // Kept `internal`: reconcile is an invisible side effect of a sidecar
    // WRITE, not a public API. The package routes its resolve-or-mint primitive
    // (`ContactsRepository.resolveOrMint…`) through it on the first
    // note/link/favorite write; there is no read/open-path reconcile.
    // `@testable import GuessWhoSync` keeps the direct-call tests compiling.
    func reconcileContactIdentity(localID: String) async throws -> IdentityReconcileReport.ContactOutcome {
        guard let contact = try await contacts.fetch(localID: localID) else {
            throw ContactStoreError.contactNotFound(localID: localID)
        }
        let result = try await reconcile(contact: contact)
        // One Case-D worth of losers; run the rewrite pass scoped to those.
        var mapping: [String: String] = [:]
        for loser in result.losers { mapping[loser] = result.winnerUUID }
        let rewrittenByLoser = try rewriteLinkEndpoints(mapping: mapping)
        var rewritten: [UUID] = []
        var seen: Set<UUID> = []
        for loser in result.losers {
            guard let ids = rewrittenByLoser[loser] else { continue }
            for id in ids where seen.insert(id).inserted {
                rewritten.append(id)
            }
        }
        return result.report.with(rewrittenLinkIDs: rewritten)
    }

    private struct ContactReconcileResult {
        let report: IdentityReconcileReport.ContactOutcome
        let carriedUUIDs: [String]
        // §13.4 inputs: contact's Case-D winner (if any) and its losers.
        // Empty when the contact didn't hit Case D this pass.
        let winnerUUID: String
        let losers: [String]
    }

    private func reconcile(contact original: Contact) async throws -> ContactReconcileResult {
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
            return try await handleCaseA(contact: &contact, malformedURLs: malformedURLs)
        case 1 where malformedURLs.isEmpty && !hadDuplicateUUID:
            return ContactReconcileResult(
                report: IdentityReconcileReport.ContactOutcome(
                    localID: contact.localID,
                    assignedUUID: nil,
                    mergedLoserUUIDs: [],
                    removedMalformedURLs: [],
                    errors: []
                ),
                carriedUUIDs: uniqueValidUUIDs,
                winnerUUID: uniqueValidUUIDs[0],
                losers: []
            )
        case 1 where malformedURLs.isEmpty:
            // Duplicate URL entries collapsed; persist the trimmed contact, no other changes.
            Self.saveLog.notice("contact save requested", metadata: [
                "op": "reconcile-dedupe", "localID": .string(contact.localID),
            ])
            try await contacts.save(contact)
            return ContactReconcileResult(
                report: IdentityReconcileReport.ContactOutcome(
                    localID: contact.localID,
                    assignedUUID: nil,
                    mergedLoserUUIDs: [],
                    removedMalformedURLs: [],
                    errors: []
                ),
                carriedUUIDs: uniqueValidUUIDs,
                winnerUUID: uniqueValidUUIDs[0],
                losers: []
            )
        case 1:
            return try await handleCaseC(contact: &contact, validUUID: uniqueValidUUIDs[0], malformedURLs: malformedURLs)
        default:
            return try await handleCaseD(contact: &contact, validUUIDs: uniqueValidUUIDs, malformedURLs: malformedURLs)
        }
    }

    private func handleCaseA(
        contact: inout Contact,
        malformedURLs: [String]
    ) async throws -> ContactReconcileResult {
        contact.urlAddresses.removeAll { url in
            url.value.hasPrefix(SidecarKey.guessWhoContactURLPrefix)
                && SidecarKey.parseGuessWhoContactURL(url.value) == nil
        }
        // Deterministic mint (plans/cli-mcp.md Revision 2): derived from the
        // contact's localID + display name, so the CLI/MCP wire can hand out
        // the same value BEFORE the mint and it stays the contact's id after.
        // Cross-device divergence is unchanged from random minting (localIDs
        // differ per device) and still converges via Case D.
        let newUUID = contact.deterministicGuessWhoID
        contact.urlAddresses.append(
            LabeledValue(label: "GuessWho", value: SidecarKey.guessWhoContactURLPrefix + newUUID)
        )
        Self.saveLog.notice("contact save requested", metadata: [
            "op": "reconcile-caseA-mint", "localID": .string(contact.localID),
        ])
        try await contacts.save(contact)

        return ContactReconcileResult(
            report: IdentityReconcileReport.ContactOutcome(
                localID: contact.localID,
                assignedUUID: newUUID,
                mergedLoserUUIDs: [],
                removedMalformedURLs: malformedURLs,
                errors: []
            ),
            carriedUUIDs: [newUUID],
            winnerUUID: newUUID,
            losers: []
        )
    }

    private func handleCaseC(
        contact: inout Contact,
        validUUID: String,
        malformedURLs: [String]
    ) async throws -> ContactReconcileResult {
        contact.urlAddresses.removeAll { url in
            url.value.hasPrefix(SidecarKey.guessWhoContactURLPrefix)
                && SidecarKey.parseGuessWhoContactURL(url.value) == nil
        }
        Self.saveLog.notice("contact save requested", metadata: [
            "op": "reconcile-caseC", "localID": .string(contact.localID),
        ])
        try await contacts.save(contact)

        return ContactReconcileResult(
            report: IdentityReconcileReport.ContactOutcome(
                localID: contact.localID,
                assignedUUID: nil,
                mergedLoserUUIDs: [],
                removedMalformedURLs: malformedURLs,
                errors: []
            ),
            carriedUUIDs: [validUUID],
            winnerUUID: validUUID,
            losers: []
        )
    }

    private func handleCaseD(
        contact: inout Contact,
        validUUIDs: [String],
        malformedURLs: [String]
    ) async throws -> ContactReconcileResult {
        let sortedUUIDs = validUUIDs.sorted()
        let winner = sortedUUIDs[0]
        let losers = Array(sortedUUIDs.dropFirst())

        let winnerKey = SidecarKey(kind: .contact, id: winner)

        // Acquire per-key sidecar locks for the winner and every loser in
        // deterministic sorted UUID order — otherwise a concurrent setField
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
        Self.saveLog.notice("contact save requested", metadata: [
            "op": "reconcile-caseD-merge", "localID": .string(contact.localID),
        ])
        try await contacts.save(contact)

        return ContactReconcileResult(
            report: IdentityReconcileReport.ContactOutcome(
                localID: contact.localID,
                assignedUUID: nil,
                mergedLoserUUIDs: mergedLoserUUIDs,
                removedMalformedURLs: malformedURLs,
                errors: errors
            ),
            carriedUUIDs: [winner],
            winnerUUID: winner,
            losers: losers
        )
    }

    // §13.4 endpoint rewrite. Runs ONCE per reconcile pass, over the union of
    // every Case-D's loser→winner mapping in the pass — so a link straddling
    // L1 (from contact-1's collapse) and L2 (from contact-2's collapse) is
    // rewritten in a single envelope write, not one per collapse.
    //
    // For each affected link envelope: acquire the per-link sidecar lock, re-
    // read inside it (covers a concurrent setLinkNote / removeLink that landed
    // since the all-keys scan started), apply all matching endpoint rewrites,
    // write once. Returns a map from loser UUID to the link UUIDs whose
    // endpoints pointed at that loser; the caller fans this out to per-contact
    // `rewrittenLinkIDs`.
    private func rewriteLinkEndpoints(mapping: [String: String]) throws -> [String: [UUID]] {
        guard !mapping.isEmpty else { return [:] }

        var rewrittenByLoser: [String: [UUID]] = [:]
        for key in try sidecars.allKeys() where key.kind == .link {
            // Cheap pre-screen against the loser set so we only lock links we
            // intend to rewrite. The authoritative read happens inside the
            // lock below; this read may be a moment stale.
            guard let pre = try sidecars.read(key) else { continue }
            guard let preA = pre.fields[Link.endpointAKey],
                  let preB = pre.fields[Link.endpointBKey],
                  let preAEnd = Link.decodeEndpoint(preA.value),
                  let preBEnd = Link.decodeEndpoint(preB.value) else { continue }
            let preAMatches = preAEnd.kind == .contact && mapping[preAEnd.id] != nil
            let preBMatches = preBEnd.kind == .contact && mapping[preBEnd.id] != nil
            guard preAMatches || preBMatches else { continue }

            try withKeyLocked(key) { ctx in
                // Re-read inside the lock: a concurrent setLinkNote or
                // removeLink may have written between the pre-screen and now.
                guard let envelope = try ctx.read() else { return }
                guard let aCell = envelope.fields[Link.endpointAKey],
                      let bCell = envelope.fields[Link.endpointBKey],
                      let aEnd = Link.decodeEndpoint(aCell.value),
                      let bEnd = Link.decodeEndpoint(bCell.value) else { return }
                let aWinner = aEnd.kind == .contact ? mapping[aEnd.id] : nil
                let bWinner = bEnd.kind == .contact ? mapping[bEnd.id] : nil
                guard aWinner != nil || bWinner != nil else { return }

                let now = Date()
                var fields = envelope.fields
                if let w = aWinner {
                    fields[Link.endpointAKey] = SidecarCell(
                        value: Link.encodeEndpoint(SidecarKey(kind: .contact, id: w)),
                        modifiedAt: now,
                        modifiedBy: deviceID
                    )
                }
                if let w = bWinner {
                    fields[Link.endpointBKey] = SidecarCell(
                        value: Link.encodeEndpoint(SidecarKey(kind: .contact, id: w)),
                        modifiedAt: now,
                        modifiedBy: deviceID
                    )
                }
                try ctx.write(
                    SidecarEnvelope(schemaVersion: 1, entityID: envelope.entityID, fields: fields)
                )

                guard let linkID = UUID(uuidString: key.id) else { return }
                // Record the link under EVERY loser whose collapse touched one
                // of its endpoints, so it surfaces in the ContactOutcome of
                // every contact whose Case D affected it. The caller dedups
                // per-contact (a link appears at most once in a given outcome's
                // rewrittenLinkIDs).
                if aWinner != nil {
                    rewrittenByLoser[aEnd.id, default: []].append(linkID)
                }
                if bWinner != nil, aEnd.id != bEnd.id {
                    rewrittenByLoser[bEnd.id, default: []].append(linkID)
                }
            }
        }
        return rewrittenByLoser
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
