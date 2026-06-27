import Foundation

/// Discriminator for the payload shape of a SidecarField's value.
/// Encodes/decodes to/from a string per the §5.2 inner `type` key.
/// Immutable after a field is created (§7.3).
public enum SidecarFieldType: String, Sendable, Codable, Equatable {
    case note           // payload is a JSON string (single-line free text)
    case multilineNote  // payload is a JSON string (multi-line free text)
    case date           // payload is a JSON string (ISO8601)
    case checkbox       // payload is a JSON bool
    // payload is a JSON OBJECT *pointer* to a separate synced binary file
    // (a `.dat` next to the envelope), NOT inline bytes:
    //   { "blobId": "<uuid>", "contentType": "image/jpeg", "byteCount": <int> }
    // The bytes live in `root/<kind>/<id>.<blobId>.dat`; the cell carries only
    // this small pointer so the synced envelope JSON stays small.
    case blob
}
