import Foundation

public struct SidecarReconcileReport: Sendable {
    public struct FileOutcome: Sendable {
        public let key: SidecarKey
        /// How many version slots the resolver examined — current (when
        /// present) plus every conflict version we successfully read off
        /// disk. Includes unparseable ones (they contribute a
        /// `skippedReasons` entry but are still counted as "considered").
        /// A non-zero `skippedReasons` with `versionsConsidered > 0` means
        /// some inputs participated and others were dropped from the fold.
        public let versionsConsidered: Int
        public let skippedReasons: [String]

        public init(key: SidecarKey, versionsConsidered: Int, skippedReasons: [String]) {
            self.key = key
            self.versionsConsidered = versionsConsidered
            self.skippedReasons = skippedReasons
        }
    }

    public let fileOutcomes: [FileOutcome]

    public init(fileOutcomes: [FileOutcome]) {
        self.fileOutcomes = fileOutcomes
    }
}
