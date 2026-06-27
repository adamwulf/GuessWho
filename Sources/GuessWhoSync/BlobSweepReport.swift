import Foundation

/// Outcome of one `sweepOrphanBlobs()` pass. Records which `.dat` payloads
/// were deleted (their `blobId` is referenced by no live `.blob` field
/// anywhere) and which keys were skipped because the sweep could not safely
/// reason about them this pass (an envelope read failed, so a referenced blob
/// might be hiding in a not-yet-readable envelope).
public struct BlobSweepReport: Sendable, Equatable {
    /// A `.dat` that was deleted because nothing references its blobId.
    public struct Deleted: Sendable, Equatable {
        public let key: SidecarKey
        public let blobId: String
        public init(key: SidecarKey, blobId: String) {
            self.key = key
            self.blobId = blobId
        }
    }

    public let deleted: [Deleted]
    /// Whether the deletion phase ran at all. The sweep is conservative: if ANY
    /// envelope could not be read this pass, the referenced-blob set may be
    /// incomplete (a live pointer could live in the unreadable envelope), so no
    /// deletions are performed and `deletionSkipped` is true. The next pass
    /// retries once the envelopes are readable.
    public let deletionSkipped: Bool
    /// Human-readable reasons a sweep step was skipped (envelope read failures,
    /// blob-listing failures). Observability only.
    public let skippedReasons: [String]

    public init(deleted: [Deleted], deletionSkipped: Bool, skippedReasons: [String]) {
        self.deleted = deleted
        self.deletionSkipped = deletionSkipped
        self.skippedReasons = skippedReasons
    }
}
