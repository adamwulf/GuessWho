import Foundation

/// A `Link` connects two-or-more entities (contact, event, or place) with a
/// free-text note. Same shape works for person↔person, person↔event,
/// person↔organization, org↔event, event↔event, place↔contact/event, and — with
/// `additionalEndpoints` — one note shared across several contacts (e.g. several
/// people who met at one event or place). Stored as one §5.2 sidecar envelope at
/// `Documents/links/<uuid>.json`. Per Core Semantics: one envelope write
/// per mutation, generic §5.3 LWW per cell, `deletedAt` is the only
/// delete mechanism.
///
/// `endpointA` / `endpointB` are the original binary endpoints and stay
/// load-bearing (every link has at least two). `additionalEndpoints` holds any
/// further participants beyond the first two; it is empty for a classic binary
/// link, so such a link's on-disk envelope is byte-for-byte identical to the
/// pre-feature format. Additional endpoints are contacts for the multi-contact
/// feature, but the type is general.
public struct Link: Hashable, Sendable, Codable {
    public var id: UUID
    public var endpointA: SidecarKey
    public var endpointB: SidecarKey
    /// Participants beyond `endpointA`/`endpointB`. Empty for a binary link.
    public var additionalEndpoints: [SidecarKey]
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
        deletedAt: Date? = nil,
        additionalEndpoints: [SidecarKey] = []
    ) {
        self.id = id
        self.endpointA = endpointA
        self.endpointB = endpointB
        self.additionalEndpoints = additionalEndpoints
        self.note = note
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.modifiedBy = modifiedBy
        self.deletedAt = deletedAt
    }
}

extension Link {
    /// Every endpoint slot in stored order, INCLUDING duplicates: the two base
    /// endpoints followed by every additional endpoint. This is the raw
    /// per-slot view — a self-link (`endpointA == endpointB`) appears twice,
    /// which is what per-slot tallies (link counts) intentionally count. Use
    /// `endpoints` when you want the deduplicated participant set.
    var endpointSlots: [SidecarKey] { [endpointA, endpointB] + additionalEndpoints }

    /// The ordered, DISTINCT set of participants: the base endpoints followed by
    /// each additional endpoint, with duplicates removed while preserving first
    /// appearance. Every participant appears exactly once, so indexing/showing a
    /// link per participant never duplicates it.
    public var endpoints: [SidecarKey] {
        var seen: Set<SidecarKey> = []
        var result: [SidecarKey] = []
        for key in endpointSlots where seen.insert(key).inserted {
            result.append(key)
        }
        return result
    }

    /// The distinct participants OTHER than `key`, in `endpoints` order. When
    /// `key` is not a participant, returns all distinct endpoints.
    public func otherEndpoints(from key: SidecarKey) -> [SidecarKey] {
        endpoints.filter { $0 != key }
    }
}

extension Link {
    // §13.2 cell keys.
    static let endpointAKey = "endpointA"
    static let endpointBKey = "endpointB"
    /// One cell holding a JSON array of `{ kind, id }` endpoint objects.
    /// Absent for a binary link (backward/forward compatible).
    static let additionalEndpointsKey = "additionalEndpoints"
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

        // Optional additionalEndpoints cell. Absent → binary link (empty). When
        // present it MUST be a JSON array of well-formed endpoints; a malformed
        // shape fails the whole link decode (same discipline as endpointA/B),
        // because silently dropping participants would lose data.
        let additionalEndpointsCell = envelope.fields[Link.additionalEndpointsKey]
        var additionalEndpoints: [SidecarKey] = []
        if let cell = additionalEndpointsCell {
            guard case .array(let items) = cell.value else { return nil }
            for item in items {
                guard let endpoint = Link.decodeEndpoint(item) else { return nil }
                additionalEndpoints.append(endpoint)
            }
        }

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

        // §13.2 derived modifiedAt/modifiedBy: max across the mutable cells
        // (endpointA, endpointB, additionalEndpoints, note, deletedAt).
        // createdAt's stamp is ignored — it can never be the most recent change.
        var maxAt = endpointACell.modifiedAt
        var maxBy = endpointACell.modifiedBy
        for cell in [endpointBCell, additionalEndpointsCell, noteCell, deletedAtCell].compactMap({ $0 }) {
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
            deletedAt: deletedAt,
            additionalEndpoints: additionalEndpoints
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

    /// Encode a list of endpoints as the JSON-array value of the
    /// `additionalEndpoints` cell.
    static func encodeAdditionalEndpoints(_ keys: [SidecarKey]) -> JSONValue {
        .array(keys.map(Link.encodeEndpoint))
    }
}

extension Link {
    // Explicit Codable so an old encoding without `additionalEndpoints` still
    // decodes (defaulting to []), and so a binary link re-encodes without the
    // key. The on-disk sidecar format is the envelope above; this conformance
    // is for callers that round-trip a `Link` value directly.
    private enum CodingKeys: String, CodingKey {
        case id, endpointA, endpointB, additionalEndpoints
        case note, createdAt, modifiedAt, modifiedBy, deletedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            endpointA: try container.decode(SidecarKey.self, forKey: .endpointA),
            endpointB: try container.decode(SidecarKey.self, forKey: .endpointB),
            note: try container.decode(String.self, forKey: .note),
            createdAt: try container.decode(Date.self, forKey: .createdAt),
            modifiedAt: try container.decode(Date.self, forKey: .modifiedAt),
            modifiedBy: try container.decode(String.self, forKey: .modifiedBy),
            deletedAt: try container.decodeIfPresent(Date.self, forKey: .deletedAt),
            additionalEndpoints: try container.decodeIfPresent([SidecarKey].self, forKey: .additionalEndpoints) ?? []
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(endpointA, forKey: .endpointA)
        try container.encode(endpointB, forKey: .endpointB)
        if !additionalEndpoints.isEmpty {
            try container.encode(additionalEndpoints, forKey: .additionalEndpoints)
        }
        try container.encode(note, forKey: .note)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(modifiedAt, forKey: .modifiedAt)
        try container.encode(modifiedBy, forKey: .modifiedBy)
        try container.encodeIfPresent(deletedAt, forKey: .deletedAt)
    }
}

extension SidecarKey {
    public static func forLink(_ link: Link) -> SidecarKey {
        SidecarKey(kind: .link, id: link.id.uuidString)
    }
}
