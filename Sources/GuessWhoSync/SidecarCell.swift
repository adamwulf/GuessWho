import Foundation

public enum SidecarCell: Sendable {
    case value(JSONValue, modifiedAt: Date, modifiedBy: String)
    case tombstone(modifiedAt: Date, modifiedBy: String)
}

extension SidecarCell: Codable {
    private enum CodingKeys: String, CodingKey {
        case value
        case deleted
        case modifiedAt
        case modifiedBy
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

        let hasValue = container.contains(.value)
        let deletedFlag = try container.decodeIfPresent(Bool.self, forKey: .deleted)
        let isTombstone = deletedFlag == true

        switch (hasValue, isTombstone) {
        case (true, true):
            throw DecodingError.dataCorruptedError(
                forKey: .deleted,
                in: container,
                debugDescription: "Cell has both 'value' and 'deleted'; exactly one must be present"
            )
        case (false, false):
            throw DecodingError.dataCorruptedError(
                forKey: .value,
                in: container,
                debugDescription: "Cell has neither 'value' nor 'deleted: true'; exactly one must be present"
            )
        case (true, false):
            let v = try container.decode(JSONValue.self, forKey: .value)
            self = .value(v, modifiedAt: modifiedAt, modifiedBy: modifiedBy)
        case (false, true):
            self = .tombstone(modifiedAt: modifiedAt, modifiedBy: modifiedBy)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .value(let v, let modifiedAt, let modifiedBy):
            try container.encode(v, forKey: .value)
            try container.encode(SidecarISO8601.string(from: modifiedAt), forKey: .modifiedAt)
            try container.encode(modifiedBy, forKey: .modifiedBy)
        case .tombstone(let modifiedAt, let modifiedBy):
            try container.encode(true, forKey: .deleted)
            try container.encode(SidecarISO8601.string(from: modifiedAt), forKey: .modifiedAt)
            try container.encode(modifiedBy, forKey: .modifiedBy)
        }
    }
}
