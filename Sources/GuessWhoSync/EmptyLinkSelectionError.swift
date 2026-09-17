import Foundation

/// Thrown by the multi-contact link writes (`addLink(from:to:[…])`,
/// `addEventLink(for:[…])`, `addPlaceLink(for:[…])`) when the requested
/// participant selection is empty — or reduces to empty after the source /
/// entity is excluded and duplicates are removed. A link needs at least two
/// distinct endpoints, so there must be at least one participant left to link.
///
/// A WRITE must never silently no-op, so an empty selection surfaces here
/// rather than quietly producing nothing.
public struct EmptyLinkSelectionError: Error, LocalizedError {
    public init() {}

    /// `LocalizedError` — plain-language, since it can reach a user-facing
    /// alert. No internal vocabulary.
    public var errorDescription: String? {
        "Select at least one contact to link."
    }
}
