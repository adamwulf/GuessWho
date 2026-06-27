import Foundation

/// The decoded view of a `.blob` field's pointer object. A `.blob` cell stores
/// a small JSON object — `{ "blobId", "contentType", "byteCount" }` — that
/// points at a separate synced binary file (`root/<kind>/<id>.<blobId>.dat`),
/// NOT the bytes themselves. This keeps the synced envelope JSON small while
/// full-resolution binary payloads (e.g. a previous contact photo) live in the
/// neighboring `.dat`.
///
/// The pointer's `blobId` is minted fresh (a UUID string) per write, so a new
/// snapshot never collides with an in-flight older `.dat` mid-sync.
public struct BlobPointer: Equatable, Sendable {
    public let blobId: String
    public let contentType: String
    public let byteCount: Int

    public init(blobId: String, contentType: String, byteCount: Int) {
        self.blobId = blobId
        self.contentType = contentType
        self.byteCount = byteCount
    }
}

extension BlobPointer {
    // Keys inside the pointer object (the `.blob` field's `value`).
    static let blobIdKey = "blobId"
    static let contentTypeKey = "contentType"
    static let byteCountKey = "byteCount"

    /// The pointer object encoded as the `.blob` field `value`.
    public var jsonValue: JSONValue {
        .object([
            BlobPointer.blobIdKey: .string(blobId),
            BlobPointer.contentTypeKey: .string(contentType),
            BlobPointer.byteCountKey: .number(Double(byteCount)),
        ])
    }

    /// Decode a pointer object from a `.blob` field's `value`. Returns nil if
    /// the shape doesn't match (mirrors `SidecarField.validate`'s `.blob` arm,
    /// but non-throwing — used by the orphan sweep to harvest live blobIds).
    public init?(from value: JSONValue) {
        guard case .object(let pointer) = value else { return nil }
        guard case .string(let blobId) = pointer[BlobPointer.blobIdKey] ?? .null,
              !blobId.isEmpty else { return nil }
        guard case .string(let contentType) = pointer[BlobPointer.contentTypeKey] ?? .null else { return nil }
        guard case .number(let count) = pointer[BlobPointer.byteCountKey] ?? .null,
              count >= 0, count.rounded() == count else { return nil }
        self.init(blobId: blobId, contentType: contentType, byteCount: Int(count))
    }
}
