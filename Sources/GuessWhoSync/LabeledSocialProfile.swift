import Foundation

public struct LabeledSocialProfile: Hashable, Sendable, Codable {
    public var label: String
    public var value: SocialProfile

    public init(label: String, value: SocialProfile) {
        self.label = label
        self.value = value
    }
}
