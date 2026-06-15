import Foundation

public struct LabeledPostalAddress: Hashable, Sendable, Codable {
    public var label: String
    public var value: PostalAddress

    public init(label: String, value: PostalAddress) {
        self.label = label
        self.value = value
    }
}
