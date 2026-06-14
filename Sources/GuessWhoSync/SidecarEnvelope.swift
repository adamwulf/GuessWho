import Foundation

public struct SidecarEnvelope: Sendable, Codable {
    public let schemaVersion: Int
    public let entityID: String
    public let fields: [String: SidecarCell]

    public init(schemaVersion: Int = 1, entityID: String, fields: [String: SidecarCell]) {
        self.schemaVersion = schemaVersion
        self.entityID = entityID
        self.fields = fields
    }
}
