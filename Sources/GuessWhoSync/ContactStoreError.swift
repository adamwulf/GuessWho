import Foundation

public enum ContactStoreError: Error, Sendable {
    case contactNotFound(localID: String)
    case groupNotFound(localID: String)
}

/// Plain-language text for the surfaces that render a thrown store error to the
/// user — the LinkedIn import's apply-failure alert reaches `contactNotFound`
/// when the record goes missing between the create and the follow-up write.
///
/// Without this conformance `localizedDescription` falls back to Foundation's
/// "The operation couldn’t be completed. (GuessWhoSync.ContactStoreError error
/// 0.)", which leaks the module and type name into an alert. The `localID` is
/// deliberately absent: it's an internal token (see `docs/contact-identity.md`)
/// and belongs in the log line, not in front of the user.
extension ContactStoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .contactNotFound:
            return "This contact is no longer available."
        case .groupNotFound:
            return "This group is no longer available."
        }
    }
}
