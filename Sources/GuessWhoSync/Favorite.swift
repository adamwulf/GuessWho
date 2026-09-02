import Foundation

public enum FavoriteKind: String, Codable, Sendable {
    case contact
    case event
    /// A Contacts.app group, keyed by its minted `GroupIdentity.id` UUID. The
    /// device-local `CNGroup.identifier` stays inside the repository's resolve
    /// boundary and is never persisted as the favorite key.
    case group
    /// An imported Apple Maps guide, keyed by its minted `MapsGuide.id` UUID.
    case guide
    /// One place inside an imported guide, keyed by its minted `MapsPlace.id`
    /// UUID. A place favorite stands on its own — it does NOT imply that the
    /// guide holding the place is favorited.
    case place
    /// A department of an organization, keyed by the organization's GuessWho
    /// UUID followed by "/" and the department name (see
    /// `DepartmentFavoriteKey`). A department is not a record — it exists only
    /// through the people who carry that department string — so the key pairs
    /// the durable, cross-device org identity with the Apple-synced department
    /// name. Favoriting a department never writes a second `.contact` favorite
    /// for the organization; the organization row is inferred from the
    /// department favorite.
    case department
}

public struct Favorite: Codable, Sendable, Hashable {
    public let kind: FavoriteKind
    /// Lowercased durable id of the referent. For `contact`/`event`/`group`/
    /// `guide`/`place` this is a single GuessWho-owned UUID (never an OS-local
    /// id). For `department` it is the composite `<org uuid>/<department name>`
    /// (see `DepartmentFavoriteKey`): the department part is not a UUID and may
    /// itself contain "/", so it is parsed by the fixed 36-character UUID prefix.
    public let id: String
    public let addedAt: Date

    /// Composite identity for SwiftUI iteration: `"contact:<uuid>"` /
    /// `"event:<uuid>"` / `"guide:<uuid>"` / `"place:<uuid>"` /
    /// `"department:<org uuid>/<department>"`. Two favorites with the same `id`
    /// but different kinds remain distinguishable — which a guide and its own
    /// places never are today, but the composite keeps that guarantee free of
    /// any per-kind uniqueness assumption.
    public var stableID: String { "\(kind.rawValue):\(id)" }

    public init(kind: FavoriteKind, id: String, addedAt: Date) {
        self.kind = kind
        self.id = id.lowercased()
        self.addedAt = addedAt
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case id
        case addedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(FavoriteKind.self, forKey: .kind)
        let id = try container.decode(String.self, forKey: .id)
        let raw = try container.decode(String.self, forKey: .addedAt)
        guard let date = SidecarISO8601.date(from: raw) else {
            throw DecodingError.dataCorruptedError(
                forKey: .addedAt,
                in: container,
                debugDescription: "addedAt is not a valid ISO8601 string: \(raw)"
            )
        }
        self.kind = kind
        self.id = id.lowercased()
        self.addedAt = date
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(id, forKey: .id)
        try container.encode(SidecarISO8601.string(from: addedAt), forKey: .addedAt)
    }

    /// Whether this favorite points at the reconciled contact identity.
    /// The app can pass opaque `ContactID` values while the package owns the
    /// bare GuessWho UUID comparison.
    public func matches(_ contactID: ContactID) -> Bool {
        kind == .contact && id == contactID.guessWhoID
    }

    /// Whether this favorite backs the app-facing favorite row identity. The
    /// raw stable string stays package-owned.
    public func matches(_ itemID: FavoriteListItem.ID) -> Bool {
        stableID == itemID.rawValue
    }
}
