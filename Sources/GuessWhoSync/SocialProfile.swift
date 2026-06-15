import Foundation

public struct SocialProfile: Hashable, Sendable, Codable {
    public var urlString: String
    public var username: String
    public var userIdentifier: String
    public var service: String

    public init(
        urlString: String = "",
        username: String = "",
        userIdentifier: String = "",
        service: String = ""
    ) {
        self.urlString = urlString
        self.username = username
        self.userIdentifier = userIdentifier
        self.service = service
    }
}
