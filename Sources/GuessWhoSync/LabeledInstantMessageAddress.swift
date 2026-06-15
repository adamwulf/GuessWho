import Foundation

public struct LabeledInstantMessageAddress: Hashable, Sendable, Codable {
    public var label: String
    public var value: InstantMessageAddress

    public init(label: String, value: InstantMessageAddress) {
        self.label = label
        self.value = value
    }
}
