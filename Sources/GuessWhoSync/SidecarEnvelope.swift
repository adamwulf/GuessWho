import Foundation

public struct SidecarEnvelope: Sendable {
    public let schemaVersion: Int
    public let entityID: String
    public let fields: [String: SidecarCell]

    public init(schemaVersion: Int = 1, entityID: String, fields: [String: SidecarCell]) {
        self.schemaVersion = schemaVersion
        self.entityID = entityID
        self.fields = fields
    }
}

extension SidecarEnvelope: Codable {
    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case entityID
        case fields
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        let entityID = try container.decode(String.self, forKey: .entityID)
        let fields = try container.decode([String: SidecarCell].self, forKey: .fields)
        self.init(schemaVersion: schemaVersion, entityID: entityID, fields: fields)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(entityID, forKey: .entityID)
        try container.encode(fields, forKey: .fields)
    }
}
