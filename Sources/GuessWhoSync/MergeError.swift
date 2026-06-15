enum MergeError: Error, Sendable {
    case entityIDMismatch
    case schemaVersionMismatch
}
