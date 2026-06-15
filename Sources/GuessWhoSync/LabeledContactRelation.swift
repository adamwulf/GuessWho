import Foundation

public struct LabeledContactRelation: Hashable, Sendable, Codable {
    public var label: String
    public var value: ContactRelation

    public init(label: String, value: ContactRelation) {
        self.label = label
        self.value = value
    }
}
