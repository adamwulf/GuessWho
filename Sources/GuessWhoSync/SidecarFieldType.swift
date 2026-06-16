import Foundation

/// Discriminator for the payload shape of a SidecarField's value.
/// Encodes/decodes to/from a string per the §5.2 inner `type` key.
/// Immutable after a field is created (§7.3).
public enum SidecarFieldType: String, Sendable, Codable, Equatable {
    case note      // payload is a JSON string (free text)
    case date      // payload is a JSON string (ISO8601)
    case checkbox  // payload is a JSON bool
}
