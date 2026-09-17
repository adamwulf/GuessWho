import Foundation

// Storage model for group folders (`plans/group-folders.md`).
//
// Folders organize groups. The relationship has ONE stored source of truth: a
// child's `parentFolder` cell names its parent folder. A folder stores no list
// of children and a group stores no folder path; the tree is always built from
// the parent assignments. A group's assignment lives on its `GroupIdentity`
// envelope (`.group`), beside the identity cell; a folder's lives on its own
// envelope (`.groupFolder`), beside its name and its deletion marker.

/// A failure in the group-folder hierarchy's storage.
public enum GroupHierarchyError: Error, Equatable, Sendable {
    /// A folder name that is empty once trimmed.
    case invalidName
    /// A folder id that is not a UUID.
    case invalidFolderID(String)
    /// No folder envelope exists for this id.
    case folderNotFound(String)
    /// The folder carries a deletion marker, so it cannot be renamed or moved.
    case folderDeleted(String)
    /// No group identity envelope exists for this id, so there is nothing to
    /// place. A group gets its identity before its first placement.
    case identityNotFound(String)
    /// The envelope at this key decoded with one or more malformed cells
    /// DROPPED (`SidecarEnvelope.cellsDroppedOnDecode`). Writing the decoded
    /// cell map back would erase those cells for good — and one of them could
    /// be a deletion marker or a placement — so every write through it is
    /// refused. The original bytes stay on disk for repair.
    case lossyEnvelope(SidecarKey)
    /// A reserved hierarchy cell at this key is structurally valid but carries
    /// a payload this build cannot trust (a name that is not a non-empty
    /// string, a parent that is neither null nor a UUID, …). The record is
    /// unavailable rather than treated as if that cell were absent.
    case recordUnavailable(SidecarKey)
    /// No timestamp strictly later than the observed assignments can be
    /// represented in the persisted format.
    case timestampOverflow
    /// The move would put a folder inside itself or one of its descendants.
    case wouldCreateCycle
}

/// A group was created in Contacts but could not then be placed in its folder.
/// The group EXISTS — it is reachable at top level — so the recovery is to retry
/// the placement with `group`, never to create again, which would leave a
/// duplicate group behind.
public struct GroupPlacementFailedError: Error {
    public let group: ContactGroup
    public let underlying: Error

    public init(group: ContactGroup, underlying: Error) {
        self.group = group
        self.underlying = underlying
    }
}

/// Folder-placement cleanup still owed for a group whose Contacts record is
/// already deleted. Deleting a group clears its placement so a later group with
/// the same name cannot inherit it; when that clear fails the deletion itself
/// has still succeeded, and this value is what lets the caller retry the clear
/// WITHOUT deleting anything again. Opaque on purpose: it carries durable group
/// identity ids, which never leave the package.
public struct PendingGroupPlacementCleanup: Sendable, Equatable {
    let identityIDs: [String]
    let observedStamps: [Date]
}

/// One stored parent assignment: a decoded `parentFolder` cell.
public struct FolderPlacement: Sendable, Hashable {
    /// The parent folder's id (canonical lowercase UUID), or nil for an
    /// EXPLICIT top-level assignment — a stamped null, or a tombstoned cell.
    /// That differs from having no placement at all: a stamped top-level
    /// assignment competes with, and can beat, an older assignment to a folder.
    public let parentFolderID: String?
    public let modifiedAt: Date
    public let modifiedBy: String

    public init(parentFolderID: String?, modifiedAt: Date, modifiedBy: String) {
        self.parentFolderID = parentFolderID?.lowercased()
        self.modifiedAt = modifiedAt
        self.modifiedBy = modifiedBy
    }
}

/// A folder's deletion marker. Its presence makes the folder deleted no matter
/// what name or parent writes arrive later, and it is never removed. It records
/// where the folder's contents were promoted to at the moment of deletion, so
/// children still pointing at the deleted folder resolve through it without
/// anyone having to rewrite them.
public struct FolderDeletion: Sendable, Hashable {
    /// The folder the contents moved up into (canonical lowercase UUID), or
    /// nil for top level.
    public let promotedToFolderID: String?
    public let modifiedAt: Date
    public let modifiedBy: String

    public init(promotedToFolderID: String?, modifiedAt: Date, modifiedBy: String) {
        self.promotedToFolderID = promotedToFolderID?.lowercased()
        self.modifiedAt = modifiedAt
        self.modifiedBy = modifiedBy
    }
}

/// One folder envelope, decoded.
public struct GroupFolderRecord: Sendable, Hashable, Identifiable {
    /// Canonical lowercase UUID. Durable and cross-device: unlike a group, a
    /// folder has no device-local counterpart to resolve.
    public let id: String
    /// Trimmed and non-empty. Folder names need not be unique.
    public let name: String
    /// The stored parent assignment, or nil when none was ever written (top
    /// level). This is the STORED value; the tree projection decides the
    /// effective parent (deleted-folder redirects, cycle suppression).
    public let placement: FolderPlacement?
    public let deletion: FolderDeletion?

    public var isDeleted: Bool { deletion != nil }

    public init(id: String, name: String, placement: FolderPlacement?, deletion: FolderDeletion?) {
        self.id = id.lowercased()
        self.name = name
        self.placement = placement
        self.deletion = deletion
    }
}

/// Everything the hierarchy is built from, as read in one pass.
public struct GroupHierarchyRecords: Sendable, Equatable {
    /// Every readable folder, live and deleted, in no particular order.
    public var folders: [GroupFolderRecord]
    /// Group identity id → its stored parent assignment, for every identity
    /// that carries one. An identity with no `parentFolder` cell is absent.
    public var groupPlacements: [String: FolderPlacement]
    /// Keys excluded from `folders` / `groupPlacements` because their data
    /// cannot be trusted: a lossy envelope or a malformed reserved cell. The
    /// tree shows the last good state for these rather than guessing.
    public var unavailableKeys: Set<SidecarKey>
    /// Keys whose read FAILED (not downloaded yet, timed out, …). Their content
    /// is unknown — which is not the same as absent — so a snapshot with any of
    /// these is incomplete and must never be read as "that folder is gone."
    public var unreadableKeys: Set<SidecarKey>

    public var isComplete: Bool { unreadableKeys.isEmpty }

    public init(
        folders: [GroupFolderRecord] = [],
        groupPlacements: [String: FolderPlacement] = [:],
        unavailableKeys: Set<SidecarKey> = [],
        unreadableKeys: Set<SidecarKey> = []
    ) {
        self.folders = folders
        self.groupPlacements = groupPlacements
        self.unavailableKeys = unavailableKeys
        self.unreadableKeys = unreadableKeys
    }
}

// MARK: - Reserved cells

/// The reserved hierarchy cells and their codecs. "Reserved" means this build
/// owns the payload shape: a malformed one makes the record unavailable. Every
/// OTHER cell in these envelopes stays opaque and rides along untouched, per
/// `docs/sidecar-compatibility.md`.
enum GroupHierarchyCells {
    /// Folder envelope: the folder's name.
    static let folderNameKey = "folderName"
    /// Folder AND group envelope: the parent folder assignment.
    static let parentFolderKey = "parentFolder"
    /// Folder envelope: the deletion marker.
    static let folderDeletedKey = "folderDeleted"

    /// Inner `type` strings for the two cells whose payload is not a plain
    /// note. They are deliberately NOT `SidecarFieldType` cases: these cells
    /// are never user-visible custom fields, and an older build keeps a cell
    /// with an unknown inner type intact.
    private static let folderReferenceType = "folderReference"
    private static let folderDeletionType = "folderDeletion"
    private static let promotedToKey = "promotedTo"

    /// What decoding one reserved cell found.
    enum Decoded<Value> {
        case absent
        case value(Value)
        case malformed
    }

    /// A folder id in canonical form, or nil when `raw` is not a UUID.
    static func canonicalFolderID(_ raw: String) -> String? {
        UUID(uuidString: raw) == nil ? nil : raw.lowercased()
    }

    /// A folder name in stored form (trimmed), or nil when nothing is left.
    static func canonicalName(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: Decode

    static func decodeName(in envelope: SidecarEnvelope) -> Decoded<String> {
        guard let cell = envelope.fields[folderNameKey] else { return .absent }
        // A name is never tombstoned by this build; a tombstone leaves the
        // folder with no trustworthy name.
        guard cell.deletedAt == nil,
              case .object(let inner) = cell.value,
              case .string(let raw) = inner[SidecarField.innerValueKey] ?? .null,
              let name = canonicalName(raw)
        else { return .malformed }
        return .value(name)
    }

    static func decodePlacement(in envelope: SidecarEnvelope) -> Decoded<FolderPlacement> {
        guard let cell = envelope.fields[parentFolderKey] else { return .absent }
        // A tombstoned placement is a stamped top-level assignment, whatever
        // value it still carries.
        if cell.deletedAt != nil {
            return .value(FolderPlacement(
                parentFolderID: nil, modifiedAt: cell.modifiedAt, modifiedBy: cell.modifiedBy))
        }
        guard case .object(let inner) = cell.value,
              let payload = inner[SidecarField.innerValueKey]
        else { return .malformed }
        switch payload {
        case .null:
            return .value(FolderPlacement(
                parentFolderID: nil, modifiedAt: cell.modifiedAt, modifiedBy: cell.modifiedBy))
        case .string(let raw):
            guard let id = canonicalFolderID(raw) else { return .malformed }
            return .value(FolderPlacement(
                parentFolderID: id, modifiedAt: cell.modifiedAt, modifiedBy: cell.modifiedBy))
        default:
            return .malformed
        }
    }

    static func decodeDeletion(in envelope: SidecarEnvelope) -> Decoded<FolderDeletion> {
        guard let cell = envelope.fields[folderDeletedKey] else { return .absent }
        // Presence is what deletes the folder, and the marker is never removed:
        // a tombstone on it is not an undelete, so `deletedAt` is ignored.
        guard case .object(let inner) = cell.value,
              case .object(let payload) = inner[SidecarField.innerValueKey] ?? .null,
              let promotedTo = payload[promotedToKey]
        else { return .malformed }
        switch promotedTo {
        case .null:
            return .value(FolderDeletion(
                promotedToFolderID: nil, modifiedAt: cell.modifiedAt, modifiedBy: cell.modifiedBy))
        case .string(let raw):
            guard let id = canonicalFolderID(raw) else { return .malformed }
            return .value(FolderDeletion(
                promotedToFolderID: id, modifiedAt: cell.modifiedAt, modifiedBy: cell.modifiedBy))
        default:
            return .malformed
        }
    }

    /// Decode a whole folder envelope. Throws `recordUnavailable` when a
    /// reserved cell is malformed or a live folder has no name.
    static func decodeFolder(_ envelope: SidecarEnvelope, key: SidecarKey) throws -> GroupFolderRecord {
        let deletion: FolderDeletion?
        switch decodeDeletion(in: envelope) {
        case .absent: deletion = nil
        case .value(let value): deletion = value
        case .malformed: throw GroupHierarchyError.recordUnavailable(key)
        }
        let placement: FolderPlacement?
        switch decodePlacement(in: envelope) {
        case .absent: placement = nil
        case .value(let value): placement = value
        case .malformed: throw GroupHierarchyError.recordUnavailable(key)
        }
        let name: String
        switch decodeName(in: envelope) {
        case .value(let value):
            name = value
        case .absent, .malformed:
            // A deleted folder is only ever followed through its marker, so its
            // name no longer matters. A LIVE folder with no usable name is not
            // a folder this build can show.
            guard deletion != nil else { throw GroupHierarchyError.recordUnavailable(key) }
            name = ""
        }
        return GroupFolderRecord(id: key.id, name: name, placement: placement, deletion: deletion)
    }

    // MARK: Encode

    static func nameValue(_ name: String, createdAt: Date) -> JSONValue {
        SidecarField.makeInnerValue(
            field: folderNameKey, type: .note, value: .string(name), createdAt: createdAt)
    }

    static func placementValue(parentFolderID: String?, createdAt: Date) -> JSONValue {
        innerValue(
            field: parentFolderKey,
            type: folderReferenceType,
            value: parentFolderID.map(JSONValue.string) ?? .null,
            createdAt: createdAt)
    }

    static func deletionValue(promotedToFolderID: String?, createdAt: Date) -> JSONValue {
        innerValue(
            field: folderDeletedKey,
            type: folderDeletionType,
            value: .object([promotedToKey: promotedToFolderID.map(JSONValue.string) ?? .null]),
            createdAt: createdAt)
    }

    private static func innerValue(
        field: String, type: String, value: JSONValue, createdAt: Date
    ) -> JSONValue {
        .object([
            SidecarField.innerFieldKey: .string(field),
            SidecarField.innerTypeKey: .string(type),
            SidecarField.innerValueKey: value,
            SidecarField.innerCreatedAtKey: .string(SidecarISO8601.string(from: createdAt)),
        ])
    }

    static func createdAt(of cell: SidecarCell?) -> Date? {
        guard case .object(let inner) = cell?.value,
              case .string(let raw) = inner[SidecarField.innerCreatedAtKey] ?? .null
        else { return nil }
        return SidecarISO8601.date(from: raw)
    }

    // MARK: Stamps

    /// The writer token for a hierarchy cell: `deviceID/operationUUID`. Merge
    /// breaks an equal-timestamp tie on this string, so two independent writes
    /// from ONE device in the same millisecond still order deterministically —
    /// a bare device id would tie. It also identifies a logical write, which is
    /// how a retry recognizes that it already landed.
    static func writerToken(deviceID: String, operationID: UUID) -> String {
        "\(deviceID)/\(operationID.uuidString.lowercased())"
    }

    /// A timestamp for a placement or deletion write: `now`, moved forward when
    /// needed so it is STRICTLY later than every assignment in `observed` at the
    /// precision that survives the wire (milliseconds). A device whose clock
    /// runs behind would otherwise write a move that loses to the very
    /// assignment it replaces. The result is round-tripped through the
    /// persisted format, so what this process compares is what a peer decodes.
    static func stamp(laterThan observed: [Date], now: Date) throws -> Date {
        var milliseconds = (now.timeIntervalSince1970 * 1_000).rounded(.down)
        if let latest = observed.max() {
            let floor = (latest.timeIntervalSince1970 * 1_000).rounded(.down) + 1
            milliseconds = max(milliseconds, floor)
        }
        // A `Double` cannot hold every millisecond exactly, so the date that
        // comes back from the persisted string can differ from `candidate`.
        // What matters is the ROUND-TRIPPED date: step forward until it clears
        // every observed stamp. The bound only stops a value the format cannot
        // hold at all (a non-parseable year) from looping.
        for _ in 0..<8 {
            guard milliseconds.isFinite else { break }
            let candidate = Date(timeIntervalSince1970: milliseconds / 1_000)
            if let persisted = SidecarISO8601.date(from: SidecarISO8601.string(from: candidate)),
               observed.allSatisfy({ $0 < persisted }) {
                return persisted
            }
            milliseconds += 1
        }
        throw GroupHierarchyError.timestampOverflow
    }
}
