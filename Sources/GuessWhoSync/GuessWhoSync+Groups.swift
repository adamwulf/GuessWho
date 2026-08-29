import Foundation

extension GuessWhoSync {
    // MARK: - Well-known group-identity cell key

    /// The single fixed cell key under which a group's whole `GroupIdentity`
    /// record is stored, JSON-encoded. A group sidecar carries exactly one
    /// cell (whole-record, whole-file last-writer-wins), so there is no need
    /// for the per-field cell layout guides/events use.
    public static let groupIdentityCellKey = "groupIdentity"

    // MARK: - Read

    /// The `GroupIdentity` record for `id`, or nil when no group sidecar exists
    /// for that UUID (an un-favorited or not-yet-synced group) or the stored
    /// cell is malformed. `id` is canonicalized to lowercase via `SidecarKey`.
    public func groupIdentity(id: String) throws -> GroupIdentity? {
        let key = SidecarKey(kind: .group, id: id)
        guard let envelope = try sidecars.read(key) else { return nil }
        return Self.decodeGroupIdentity(from: envelope)
    }

    /// Every stored `GroupIdentity`, unordered. O(N) over the group sidecars;
    /// malformed records are skipped. Reads propagate (a not-yet-downloaded
    /// sidecar throws, like `allGuides()`), so the caller sees a transient
    /// iCloud state rather than a silently short list.
    public func allGroupIdentities() throws -> [GroupIdentity] {
        try groupIdentities(at: sidecars.allKeys())
    }

    /// Reload-internal form that consumes an already-enumerated corpus key
    /// snapshot. This preserves `allGroupIdentities()` decoding/filtering while
    /// avoiding a second `allKeys()` during `ContactsRepository.reload()`.
    func groupIdentities(at keys: [SidecarKey]) throws -> [GroupIdentity] {
        var result: [GroupIdentity] = []
        for key in keys where key.kind == .group {
            guard let envelope = try sidecars.read(key) else { continue }
            if let record = Self.decodeGroupIdentity(from: envelope) {
                result.append(record)
            }
        }
        return result
    }

    // MARK: - Write / mint

    /// Persist a `GroupIdentity`. Scalar fields (`name`/`account`/`memberCount`/
    /// `memberHash`/`hashedMemberCount`) are taken from `record` as the new
    /// truth (whole-record last-writer-wins). The `deviceLocalIDs` map, however,
    /// is stamped for THIS device's slot ONLY: the persisted map starts from
    /// whatever is already on disk (so other devices' slots survive untouched),
    /// then this device's slot is set from `record.deviceLocalIDs[deviceID]`, or
    /// pruned when `record` omits it. That is what lets a device pin or prune its
    /// own dangling handle without ever clobbering a peer's entry.
    ///
    /// The whole read-merge-write runs under the key's `withKeyLocked` so the
    /// slot merge is atomic against a concurrent same-key write.
    public func writeGroupIdentity(_ record: GroupIdentity) throws {
        let key = SidecarKey(kind: .group, id: record.id)
        try withKeyLocked(key) { ctx in
            let existing = try ctx.read()
            let existingRecord = existing.flatMap { Self.decodeGroupIdentity(from: $0) }

            var mergedMap = existingRecord?.deviceLocalIDs ?? [:]
            if let mine = record.deviceLocalIDs[deviceID] {
                mergedMap[deviceID] = mine
            } else {
                mergedMap.removeValue(forKey: deviceID)
            }

            var merged = record
            merged.deviceLocalIDs = mergedMap

            // Idempotent write: when the merged record is byte-for-byte the
            // record already on disk, skip the write entirely. Otherwise every
            // `loadGroups()` / membership refresh would stamp a fresh
            // `modifiedAt`, re-upload an unchanged file to iCloud, and provoke
            // peers to rewrite it with their own stamp — perpetual low-grade
            // cross-device churn on data that never changed.
            if let existingRecord, merged == existingRecord {
                return
            }

            let json = try Self.encodeGroupIdentityJSON(merged)
            let now = Date()
            // Preserve the record cell's original createdAt across updates
            // (mirrors writeWellKnownCell); the singleton has no user-facing
            // createdAt, but a stable stamp keeps the encoded bytes churn-free.
            let createdAt = Self.groupIdentityCreatedAt(in: existing) ?? now
            let inner = SidecarField.makeInnerValue(
                field: Self.groupIdentityCellKey,
                type: .note,
                value: .string(json),
                createdAt: createdAt
            )
            let cell = SidecarCell(value: inner, modifiedAt: now, modifiedBy: deviceID)
            var fields = existing?.fields ?? [:]
            fields[Self.groupIdentityCellKey] = cell
            let envelope = SidecarEnvelope(
                schemaVersion: 1,
                entityID: existing?.entityID ?? key.id,
                fields: fields
            )
            try ctx.write(envelope)
        }
    }

    /// Mint a brand-new `GroupIdentity` for a favorited group: a fresh
    /// cross-device UUID, the normalized name, and this device's slot seeded
    /// from `localID` (nil for the rare case of minting a record before the
    /// current device has resolved its own group). Persists it and returns it.
    ///
    /// The caller supplies `memberCount` (the TOTAL membership, including
    /// members with no GuessWho ID yet) and the `memberHash`/`hashedMemberCount`
    /// pair from `GroupIdentity.fingerprint(forGuessWhoIDs:)` over the reconciled
    /// members only — so un-reconciled members stay counted while the hash stays
    /// advisory.
    @discardableResult
    public func mintGroupIdentity(
        name: String,
        account: String? = nil,
        memberCount: Int,
        memberHash: String,
        hashedMemberCount: Int,
        localID: String?
    ) throws -> GroupIdentity {
        let record = GroupIdentity(
            id: UUID().uuidString.lowercased(),
            name: GroupIdentity.normalizedName(name),
            account: account,
            memberCount: memberCount,
            memberHash: memberHash,
            hashedMemberCount: hashedMemberCount,
            deviceLocalIDs: localID.map { [deviceID: $0] } ?? [:]
        )
        try writeGroupIdentity(record)
        return record
    }

    // MARK: - Private encode / decode

    private static func decodeGroupIdentity(from envelope: SidecarEnvelope) -> GroupIdentity? {
        guard let cell = envelope.fields[groupIdentityCellKey],
              cell.deletedAt == nil,
              case .object(let inner) = cell.value,
              case .string(let json) = inner[SidecarField.innerValueKey] ?? .null,
              let data = json.data(using: .utf8),
              let record = try? JSONDecoder().decode(GroupIdentity.self, from: data)
        else { return nil }
        return record
    }

    private static func encodeGroupIdentityJSON(_ record: GroupIdentity) throws -> String {
        let encoder = JSONEncoder()
        // Sorted keys so two devices that fold the same record write
        // byte-identical output — the same convergence discipline
        // `SidecarEnvelopeCodec` enforces on the outer envelope.
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(record)
        return String(decoding: data, as: UTF8.self)
    }

    private static func groupIdentityCreatedAt(in envelope: SidecarEnvelope?) -> Date? {
        guard let cell = envelope?.fields[groupIdentityCellKey],
              case .object(let inner) = cell.value,
              case .string(let raw) = inner[SidecarField.innerCreatedAtKey] ?? .null
        else { return nil }
        return SidecarISO8601.date(from: raw)
    }
}
