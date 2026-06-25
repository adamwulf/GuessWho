import Foundation

public struct ContactIdentityDebugInfo: Hashable, Sendable {
    public let localID: String
    public let guessWhoID: String?
    public let guessWhoURLs: [LabeledValue]

    public init(localID: String, guessWhoID: String?, guessWhoURLs: [LabeledValue]) {
        self.localID = localID
        self.guessWhoID = guessWhoID
        self.guessWhoURLs = guessWhoURLs
    }
}
