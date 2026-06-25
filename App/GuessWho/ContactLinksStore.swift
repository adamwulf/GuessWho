import Foundation
import GuessWhoSync

/// App-side alias for the package's `Link` type, so SwiftUI files that
/// also import `SwiftUI.Link` can spell the contact-to-contact link as
/// `ContactLink` without a fully-qualified prefix (the package shares its
/// name with the module, so `GuessWhoSync.Link` doesn't resolve).
typealias ContactLink = Link

/// Sort-key tuple chosen so a freshly-added link lands at the bottom of
/// the list deterministically across devices.
private func linkSortKey(_ link: ContactLink) -> (Date, String) {
    (link.createdAt, link.id.uuidString)
}

/// App-side view model exposing a contact's contact↔contact links as a
/// SwiftUI-observable property, routing mutations through the package's
/// `ContactsRepository` keyed on the opaque `ContactID`.
///
/// Writes are `async`: the repository resolves-or-mints BOTH endpoints'
/// GuessWho UUIDs first (linking a never-touched contact reconciles + mints,
/// transparent to us), then writes the durable `Link`. Reads stay synchronous —
/// an unreconciled contact has no links yet, so `repository.links(for:)`
/// returns empty until a write mints the UUID.
@MainActor
@Observable
final class ContactLinksStore {
    private let repository: ContactsRepository
    /// The opaque identity the links are keyed on. Carries the contact's current
    /// `guessWhoID`, which the repository reads links off. The first `addLink`
    /// on an unreconciled contact MINTS the UUID internally; our captured `id`
    /// still has a nil `guessWhoID`, so we `reresolve()` it post-write to pick up
    /// the minted UUID — otherwise the reload would read off the stale nil-UUID
    /// id and miss the just-written link.
    private(set) var id: ContactID

    private(set) var links: [Link] = []

    init(repository: ContactsRepository, id: ContactID) {
        self.repository = repository
        self.id = id
        reload()
    }

    func reload() {
        let raw = repository.links(for: id)
        links = raw.sorted { linkSortKey($0) < linkSortKey($1) }
    }

    /// Re-derive `id` after a write that may have minted the GuessWho UUID.
    /// `contact(id:)` is reconcile-stable (resolves via the captured id's
    /// always-present `localID` even when its `guessWhoID` is still nil), so this
    /// picks up the just-minted UUID. Harmless when nothing minted — it re-derives
    /// the same id. Keeps the old id when the contact is gone (deleted).
    private func reresolve() {
        guard let contact = repository.contact(id: id) else { return }
        id = contact.contactID
    }

    @discardableResult
    func addLink(to other: ContactID, note: String) async -> Link? {
        let result: Link?
        do {
            result = try await repository.addLink(from: id, to: other, note: note)
        } catch {
            result = nil
        }
        reresolve()
        reload()
        return result
    }

    func setNote(id linkID: UUID, note: String) {
        do {
            try repository.setLinkNote(id: linkID, note: note)
        } catch {
            // ignore — reload reflects the truth
        }
        reload()
    }

    func remove(id linkID: UUID) {
        do {
            try repository.removeLink(id: linkID)
        } catch {
            // ignore — reload reflects the truth
        }
        reload()
    }
}
