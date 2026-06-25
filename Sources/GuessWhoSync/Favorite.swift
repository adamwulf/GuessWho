import Foundation

public enum FavoriteKind: String, Codable, Sendable {
    case contact
    case event
}

public struct Favorite: Codable, Sendable, Hashable {
    public let kind: FavoriteKind
    /// Lowercased UUID of the referent (the contact or event sidecar UUID).
    public let id: String
    public let addedAt: Date

    /// Composite identity for SwiftUI iteration: `"contact:<uuid>"` /
    /// `"event:<uuid>"`. Two favorites with the same `id` but different
    /// kinds remain distinguishable, even though the current schema never
    /// produces a collision.
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
}
