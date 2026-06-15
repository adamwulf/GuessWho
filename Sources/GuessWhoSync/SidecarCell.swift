import Foundation

public struct SidecarCell: Sendable {
    public var value: JSONValue
    public var modifiedAt: Date
    public var modifiedBy: String
    public var deletedAt: Date?

    public init(
        value: JSONValue,
        modifiedAt: Date,
        modifiedBy: String,
        deletedAt: Date? = nil
    ) {
        self.value = value
        self.modifiedAt = modifiedAt
        self.modifiedBy = modifiedBy
        self.deletedAt = deletedAt
    }
}

extension SidecarCell: Codable {
    private enum CodingKeys: String, CodingKey {
        case value
        case modifiedAt
        case modifiedBy
        case deletedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let modifiedAtString = try container.decode(String.self, forKey: .modifiedAt)
        guard let modifiedAt = SidecarISO8601.date(from: modifiedAtString) else {
            throw DecodingError.dataCorruptedError(
                forKey: .modifiedAt,
                in: container,
                debugDescription: "modifiedAt is not a valid ISO8601 UTC timestamp"
            )
        }
        let modifiedBy = try container.decode(String.self, forKey: .modifiedBy)
        let value = try container.decode(JSONValue.self, forKey: .value)

        var deletedAt: Date? = nil
        if let raw = try container.decodeIfPresent(String.self, forKey: .deletedAt) {
            guard let parsed = SidecarISO8601.date(from: raw) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .deletedAt,
                    in: container,
                    debugDescription: "deletedAt is not a valid ISO8601 UTC timestamp"
                )
            }
            deletedAt = parsed
        }

        self.init(value: value, modifiedAt: modifiedAt, modifiedBy: modifiedBy, deletedAt: deletedAt)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(value, forKey: .value)
        try container.encode(SidecarISO8601.string(from: modifiedAt), forKey: .modifiedAt)
        try container.encode(modifiedBy, forKey: .modifiedBy)
        if let deletedAt {
            try container.encode(SidecarISO8601.string(from: deletedAt), forKey: .deletedAt)
        }
    }
}
