import Foundation

public struct SidecarReconcileReport: Sendable {
    public struct FileOutcome: Sendable {
        public let key: SidecarKey
        /// How many version slots participated in the merge that was
        /// written to disk — current (when present and read OK) plus every
        /// conflict version that was successfully read AND fed to the
        /// resolver AND used in the resulting write. Includes unparseable
        /// ones (they contribute a `skippedReasons` entry but were still
        /// passed to the resolver).
        ///
        /// **Zero on aborts.** When the pass aborts (read-failure on any
        /// byte, resolver throws, resolver returned mismatched-entityID
        /// envelope) the value is 0 — nothing was written, no version was
        /// removed. Inspect `skippedReasons` for the cause; the next
        /// reconcile retries the same key.
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
