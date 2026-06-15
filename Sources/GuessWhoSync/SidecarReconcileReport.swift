import Foundation

public struct SidecarReconcileReport: Sendable {
    public struct FileOutcome: Sendable {
        public let key: SidecarKey
        public let mergedVersionCount: Int
        public let skippedReasons: [String]

        public init(key: SidecarKey, mergedVersionCount: Int, skippedReasons: [String]) {
            self.key = key
            self.mergedVersionCount = mergedVersionCount
            self.skippedReasons = skippedReasons
        }
    }

    public let fileOutcomes: [FileOutcome]

    public init(fileOutcomes: [FileOutcome]) {
        self.fileOutcomes = fileOutcomes
    }
}
