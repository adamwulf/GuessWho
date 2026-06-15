import Foundation

public struct InstantMessageAddress: Hashable, Sendable, Codable {
    public var username: String
    public var service: String

    public init(username: String = "", service: String = "") {
        self.username = username
        self.service = service
    }
}
