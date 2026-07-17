import Foundation

/// One agent-originated write, as recorded in the device-local audit log
/// (plans/cli-mcp.md Phase 2).
///
/// `modifiedBy` on the sidecar cells is the SAME per-install device UUID for
/// UI and agent writes, so this log is the ONLY provenance record that a
/// change came from an agent. Entries record the DURABLE internal referent
/// (the storage key + the written instance UUID + the post-write
/// `modifiedAt`) — HOST-SIDE ONLY, never on the wire — plus a display-name
/// snapshot so the app can render plain rows ("Added note to Jane Doe")
/// even after the record itself is gone.
public struct MCPAuditEntry: Codable, Sendable {
    public enum Action: String, Codable, Sendable {
        case addNote, editNote, deleteNote
        case setCustomField, deleteCustomField
        case addLinkedContact, removeLinkedContact
        case setFavorite
        case addTag, editTag, deleteTag
        case createGuide, deleteGuide, reorderPlaces, deletePlace
        // Contact-record writes (Revision 2). `deleteContact` is only ever
        // recorded AFTER the user approved the in-app confirmation.
        case createContact, editContact, deleteContact
    }

    public enum SubjectKind: String, Codable, Sendable {
        case contact, event, guide, place, link
    }

    /// When the entry was appended (immediately after the engine write
    /// returned — append-AFTER-write, so a crash can lose one entry but can
    /// never record a phantom write).
    public let at: Date
    public let action: Action
    public let subjectKind: SubjectKind
    /// The durable id of the record the write landed on: the contact's
    /// GuessWho UUID, the event/guide/place record UUID, or the link's own
    /// UUID. Never an Apple local identifier.
    public let subjectID: String
    /// Display-name snapshot at write time ("Jane Doe", an event title, a
    /// guide name) so rows stay renderable after the record changes.
    public let subjectName: String
    /// The written instance (note / custom field / tag cell / link) UUID,
    /// when the action targets one.
    public let instanceID: String?
    /// The instance's `modifiedAt` AFTER this write — the Recently Deleted
    /// restore guard compares the live cell against this: a mismatch means
    /// something else (a human, another device) touched the cell since, and
    /// a blind restore would clobber that newer edit.
    public let postModifiedAt: Date?
    /// The value before an edit/delete (a note body, tag text, field value,
    /// link note, a deleted guide's source link) — the restore payload.
    public let priorValue: String?
    /// The value this write set, for display.
    public let newValue: String?

    public init(
        at: Date, action: Action, subjectKind: SubjectKind, subjectID: String,
        subjectName: String, instanceID: String?, postModifiedAt: Date?,
        priorValue: String?, newValue: String?
    ) {
        self.at = at
        self.action = action
        self.subjectKind = subjectKind
        self.subjectID = subjectID
        self.subjectName = subjectName
        self.instanceID = instanceID
        self.postModifiedAt = postModifiedAt
        self.priorValue = priorValue
        self.newValue = newValue
    }
}

/// The device-local agent-activity log: one JSON line per entry, appended
/// AFTER the engine write returns.
///
/// DEVICE-LOCAL BY DESIGN — the file must never live in the synced sidecar
/// root or any iCloud container: synced audit entries would be LWW-merged
/// across devices and would burn the very iCloud quota the write budget
/// protects. The app passes a URL under its own Application Support
/// directory; tests pass a temp path.
///
/// Dates are encoded as epoch seconds (not ISO 8601) so the sub-second
/// precision of the `modifiedAt` stamps survives the round-trip — the
/// restore guard compares them against live cell values.
public actor MCPAuditLog {
    private let fileURL: URL
    /// Trim threshold: when a load sees more than `maxEntries`, the oldest
    /// are dropped and the file rewritten. Generous vs. the rate-limited
    /// write budget; keeps the file from growing without bound.
    private let maxEntries: Int
    private var cache: [MCPAuditEntry]?

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()

    public init(fileURL: URL, maxEntries: Int = 2000) {
        self.fileURL = fileURL
        self.maxEntries = maxEntries
    }

    /// Append one entry. Best-effort: an audit failure must never fail the
    /// write it records (the write already happened), so errors are
    /// swallowed after noting them to stderr via the entry cache staying
    /// coherent either way.
    public func record(_ entry: MCPAuditEntry) {
        var entries = loadIfNeeded()
        entries.append(entry)
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
            cache = entries
            rewrite(entries)
            return
        }
        cache = entries
        guard let data = try? Self.encoder.encode(entry) else { return }
        var line = data
        line.append(0x0A)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: line)
            }
        } else {
            try? FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try? line.write(to: fileURL)
        }
    }

    /// Every recorded entry, oldest first.
    public func entries() -> [MCPAuditEntry] {
        loadIfNeeded()
    }

    private func loadIfNeeded() -> [MCPAuditEntry] {
        if let cache { return cache }
        guard let data = try? Data(contentsOf: fileURL) else {
            cache = []
            return []
        }
        let loaded = data.split(separator: 0x0A).compactMap {
            try? Self.decoder.decode(MCPAuditEntry.self, from: Data($0))
        }
        cache = loaded
        return loaded
    }

    private func rewrite(_ entries: [MCPAuditEntry]) {
        var data = Data()
        for entry in entries {
            guard let encoded = try? Self.encoder.encode(entry) else { continue }
            data.append(encoded)
            data.append(0x0A)
        }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try? data.write(to: fileURL)
    }
}
