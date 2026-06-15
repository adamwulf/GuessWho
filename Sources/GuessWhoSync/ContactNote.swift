import Foundation

public struct ContactNote: Hashable, Sendable, Codable {
    public var id: UUID
    public var createdAt: Date
    public var modifiedAt: Date
    public var modifiedBy: String
    public var body: String
    public var deleted: Bool

    public init(
        id: UUID,
        createdAt: Date,
        modifiedAt: Date,
        modifiedBy: String,
        body: String,
        deleted: Bool
    ) {
        self.id = id
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.modifiedBy = modifiedBy
        self.body = body
        self.deleted = deleted
    }
}
