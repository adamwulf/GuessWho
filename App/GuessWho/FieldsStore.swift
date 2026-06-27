import Foundation
import GuessWhoSync

/// App-side view model exposing a contact's named key/value sidecar fields
/// (e.g. "LinkedIn About", "LinkedIn Location") as an observable list, keyed on
/// the opaque `ContactID`. Mirrors `NotesStore`. Reads are synchronous and
/// return empty for an unreconciled contact (no mint on read). The package owns
/// the authoritative store; we just reload after the id may have changed.
@MainActor
@Observable
final class FieldsStore {
    private let repository: ContactsRepository
    private(set) var id: ContactID
    /// Live fields, sorted by field name for stable display.
    private(set) var fields: [SidecarField] = []

    init(repository: ContactsRepository, id: ContactID) {
        self.repository = repository
        self.id = id
        reload()
    }

    func reload() {
        fields = repository.fields(for: id).sorted { $0.field < $1.field }
    }

    /// Re-derive `id` (in case a write elsewhere minted the GuessWho UUID), then
    /// reload. `contact(id:)` is reconcile-stable via the captured id's localID.
    func reresolveAndReload() {
        if let contact = repository.contact(id: id) {
            id = contact.contactID
        }
        reload()
    }
}
