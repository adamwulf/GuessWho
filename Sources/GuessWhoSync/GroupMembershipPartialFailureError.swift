import Foundation

/// Thrown by the `ContactsRepository` group-membership batch writes
/// (`addContacts(_:toGroup:)` / `removeContacts(_:fromGroup:)`) when SOME of
/// the requested contacts ended in the requested state and some did not.
///
/// Those batches deliberately run to COMPLETION rather than stopping at the
/// first store failure — one unwritable contact must not cancel the writes the
/// user asked for on the rest of a selection — so the caller needs a report
/// that says exactly what landed. This is that report. The contract:
///
/// - **No throw** → every requested contact ended in the requested state.
/// - **This error** → the batch ran to the end. `applied` names the contacts
///   that ended in the requested state, `failures` names the ones that did not
///   (each with the store error that stopped it), and together they account for
///   every requested contact. `applied` may be empty — that means "none
///   landed", NOT "nothing was attempted"; `failures` is never empty.
/// - **Any other error** → the pre-flight membership read failed, so nothing
///   was attempted and no contact changed.
///
/// The single-contact conveniences (`addContact(_:toGroup:)` /
/// `removeContact(_:fromGroup:)`) never throw this: one contact has no partial
/// state, so they rethrow the underlying store error unchanged.
public struct GroupMembershipPartialFailureError: Error, LocalizedError {
    /// Which way the batch was moving membership. Carried only so the message
    /// below reads correctly for both directions.
    public enum Change: Equatable, Sendable {
        case addition
        case removal
    }

    /// One contact the batch could not write, with the error that stopped it.
    public struct Failure {
        /// The requested contact, echoed back exactly as the caller passed it
        /// in — so the UI can still NAME it even when the record has vanished
        /// from Contacts, which is precisely what a `contactNotFound` failure
        /// means. (Re-resolving it through the repository would return nil.)
        public let contact: Contact

        /// The store error for this one contact, unwrapped — e.g.
        /// `ContactStoreError.contactNotFound`. Kept typed rather than
        /// flattened to a string so a caller can still switch on it.
        public let error: any Error

        public init(contact: Contact, error: any Error) {
            self.contact = contact
            self.error = error
        }
    }

    public let change: Change
    public let group: ContactGroup

    /// The requested contacts that ended in the requested state. Includes any
    /// that were ALREADY there and needed no write — the caller asked for an
    /// end state, and those contacts are in it.
    public let applied: [Contact]

    /// The requested contacts that did not. Never empty: an all-succeeded batch
    /// does not throw.
    public let failures: [Failure]

    public init(
        change: Change,
        group: ContactGroup,
        applied: [Contact],
        failures: [Failure]
    ) {
        self.change = change
        self.group = group
        self.applied = applied
        self.failures = failures
    }

    /// `LocalizedError` because these batches are user-initiated: an alert that
    /// renders `localizedDescription` shows this verbatim, so it is product
    /// copy — plain language, counted so the user knows how much landed. A
    /// caller with room for more detail can name the individual `failures`.
    public var errorDescription: String? {
        let total = applied.count + failures.count
        let verb = change == .addition ? "added to" : "removed from"
        if total == 1 {
            return "This contact couldn’t be \(verb) “\(group.name).”"
        }
        if applied.isEmpty {
            return "None of these \(total) contacts could be \(verb) “\(group.name).”"
        }
        return "\(failures.count) of \(total) contacts couldn’t be \(verb) “\(group.name).”"
    }
}
