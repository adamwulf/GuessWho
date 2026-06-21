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

@MainActor
@Observable
final class ContactLinksStore {
    private let service: SyncService
    let contactUUID: String

    private(set) var links: [Link] = []

    init(service: SyncService, contactUUID: String) {
        self.service = service
        self.contactUUID = contactUUID
        reload()
    }

    func reload() {
        let raw = service.contactLinks(forContactUUID: contactUUID)
        links = raw.sorted { linkSortKey($0) < linkSortKey($1) }
    }

    @discardableResult
    func addLink(toUUID: String, note: String) -> Link? {
        let result: Link?
        do {
            result = try service.addContactLink(fromUUID: contactUUID, toUUID: toUUID, note: note)
        } catch {
            result = nil
        }
        reload()
        return result
    }

    func setNote(id: UUID, note: String) {
        do {
            try service.setContactLinkNote(id: id, note: note)
        } catch {
            // ignore — reload reflects the truth
        }
        reload()
    }

    func remove(id: UUID) {
        do {
            try service.removeContactLink(id: id)
        } catch {
            // ignore — reload reflects the truth
        }
        reload()
    }
}
