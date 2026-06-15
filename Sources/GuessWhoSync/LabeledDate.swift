import Foundation

public struct LabeledDate: Hashable, Sendable, Codable {
    public var label: String
    public var value: DateComponents

    public init(label: String, value: DateComponents) {
        self.label = label
        self.value = value
    }
}
