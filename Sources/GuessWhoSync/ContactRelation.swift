import Foundation

public struct ContactRelation: Hashable, Sendable, Codable {
    public var name: String

    public init(name: String = "") {
        self.name = name
    }
}
