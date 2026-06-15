import Foundation

/// A `Link` connects two entities (contact or event) with a free-text note.
/// Same shape works for person↔person, person↔event, person↔organization,
/// org↔event, event↔event. Stored as one §5.2 sidecar envelope at
/// `Documents/links/<uuid>.json`. Per Core Semantics: one envelope write
/// per mutation, generic §5.3 LWW per cell, `deletedAt` is the only
/// delete mechanism.
public struct Link: Hashable, Sendable {
    public var id: UUID
    public var endpointA: SidecarKey
    public var endpointB: SidecarKey
    public var note: String
    public var createdAt: Date
    public var modifiedAt: Date
    public var modifiedBy: String
    public var deletedAt: Date?

    public init(
        id: UUID,
        endpointA: SidecarKey,
        endpointB: SidecarKey,
        note: String,
        createdAt: Date,
        modifiedAt: Date,
        modifiedBy: String,
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.endpointA = endpointA
        self.endpointB = endpointB
        self.note = note
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.modifiedBy = modifiedBy
        self.deletedAt = deletedAt
    }
}

extension Link {
    // §13.2 cell keys.
    static let endpointAKey = "endpointA"
    static let endpointBKey = "endpointB"
    static let noteKey = "note"
    static let createdAtKey = "createdAt"
    static let deletedAtKey = "deletedAt"

    /// Decode a link envelope per §13.2. Returns nil if any required cell
    /// is missing or carries an unparseable value.
    public init?(from envelope: SidecarEnvelope) {
        guard envelope.schemaVersion == 1 else { return nil }
        guard let envelopeID = UUID(uuidString: envelope.entityID) else { return nil }

        guard let endpointACell = envelope.fields[Link.endpointAKey],
              let endpointA = Link.decodeEndpoint(endpointACell.value) else { return nil }
        guard let endpointBCell = envelope.fields[Link.endpointBKey],
              let endpointB = Link.decodeEndpoint(endpointBCell.value) else { return nil }
        guard let noteCell = envelope.fields[Link.noteKey],
              case .string(let noteText) = noteCell.value else { return nil }
        guard let createdAtCell = envelope.fields[Link.createdAtKey],
              case .string(let createdAtRaw) = createdAtCell.value,
              let createdAt = SidecarISO8601.date(from: createdAtRaw) else { return nil }

        // Optional deletedAt cell. Live when absent OR present with `value: null`.
        let deletedAtCell = envelope.fields[Link.deletedAtKey]
        var deletedAt: Date? = nil
        if let cell = deletedAtCell {
            switch cell.value {
            case .null:
                deletedAt = nil
            case .string(let raw):
                guard let parsed = SidecarISO8601.date(from: raw) else { return nil }
                deletedAt = parsed
            default:
                return nil
            }
        }

        // §13.2 derived modifiedAt/modifiedBy: max across the four mutable
        // cells (endpointA, endpointB, note, deletedAt). createdAt's stamp
        // is ignored — it can never be the most recent change.
        var maxAt = endpointACell.modifiedAt
        var maxBy = endpointACell.modifiedBy
        for cell in [endpointBCell, noteCell, deletedAtCell].compactMap({ $0 }) {
            if cell.modifiedAt > maxAt {
                maxAt = cell.modifiedAt
                maxBy = cell.modifiedBy
            } else if cell.modifiedAt == maxAt, cell.modifiedBy > maxBy {
                maxBy = cell.modifiedBy
            }
        }

        self.init(
            id: envelopeID,
            endpointA: endpointA,
            endpointB: endpointB,
            note: noteText,
            createdAt: createdAt,
            modifiedAt: maxAt,
            modifiedBy: maxBy,
            deletedAt: deletedAt
        )
    }

    /// Decode a `{ kind, id }` JSON object into a `SidecarKey`.
    static func decodeEndpoint(_ value: JSONValue) -> SidecarKey? {
        guard case .object(let inner) = value else { return nil }
        guard case .string(let kindRaw) = inner["kind"] ?? .null,
              let kind = SidecarKind(rawValue: kindRaw) else { return nil }
        guard case .string(let id) = inner["id"] ?? .null else { return nil }
        return SidecarKey(kind: kind, id: id)
    }

    /// Encode a `SidecarKey` as a `{ kind, id }` JSON object.
    static func encodeEndpoint(_ key: SidecarKey) -> JSONValue {
        .object([
            "kind": .string(key.kind.rawValue),
            "id": .string(key.id),
        ])
    }
}

extension SidecarKey {
    public static func forLink(_ link: Link) -> SidecarKey {
        SidecarKey(kind: .link, id: link.id.uuidString)
    }
}
