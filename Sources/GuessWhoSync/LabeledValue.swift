import Foundation

public struct LabeledValue: Hashable, Sendable, Codable {
    public var label: String
    public var value: String

    public init(label: String, value: String) {
        self.label = label
        self.value = value
    }
}
