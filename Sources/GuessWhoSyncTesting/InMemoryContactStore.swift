import Foundation
import GuessWhoSync

public final class InMemoryContactStore: ContactStoreProtocol {
    private let lock = NSLock()
    private var contactsByID: [String: Contact]
    private var imageSideband: [String: (image: Data?, thumbnail: Data?)] = [:]

    /// Internal-only counter used by tests to assert that bulk `fetchAll()`
    /// never peeks into the image sideband. Increments whenever the store
    /// reads or writes `imageSideband` — either via the test-only
    /// `setImageData(...)`, via `loadImageData` / `loadThumbnailImageData`,
    /// or via the auto-correct path inside `fetch(localID:)`.
    public private(set) var imageSidebandAccessCount: Int = 0

    public init(contacts: [Contact] = []) {
        var initial: [String: Contact] = [:]
        for contact in contacts {
            initial[contact.localID] = contact
        }
        self.contactsByID = initial
    }

    public func fetchAll() throws -> [Contact] {
        lock.lock()
        defer { lock.unlock() }
        // §7.4 — bulk path must NOT peek at the sideband. Return whatever the
        // persisted flag says, full stop.
        return Array(contactsByID.values)
    }

    public func fetch(localID: String) throws -> Contact? {
        lock.lock()
        defer { lock.unlock() }
        guard var contact = contactsByID[localID] else { return nil }
        // §7.4 — single-contact path auto-corrects `imageDataAvailable`
        // against the sideband. This peek is allowed; bulk fetchAll is not.
        imageSidebandAccessCount += 1
        let bytes = imageSideband[localID]
        let hasBytes = (bytes?.image != nil) || (bytes?.thumbnail != nil)
        if contact.imageDataAvailable != hasBytes {
            contact.imageDataAvailable = hasBytes
            contactsByID[localID] = contact
        }
        return contact
    }

    public func save(_ contact: Contact) throws {
        lock.lock()
        defer { lock.unlock() }
        let previous = contactsByID[contact.localID]
        contactsByID[contact.localID] = contact
        // §7.4 — clear sideband ONLY on a true→false transition.
        if let previous, previous.imageDataAvailable == true, contact.imageDataAvailable == false {
            imageSidebandAccessCount += 1
            imageSideband.removeValue(forKey: contact.localID)
        }
    }

    public func loadImageData(localID: String) throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard contactsByID[localID] != nil else {
            throw ContactStoreError.contactNotFound(localID: localID)
        }
        imageSidebandAccessCount += 1
        return imageSideband[localID]?.image
    }

    public func loadThumbnailImageData(localID: String) throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard contactsByID[localID] != nil else {
            throw ContactStoreError.contactNotFound(localID: localID)
        }
        imageSidebandAccessCount += 1
        return imageSideband[localID]?.thumbnail
    }

    /// Test-only setter for attaching image / thumbnail bytes to a contact.
    /// Does not flip `imageDataAvailable` on the stored `Contact`; the
    /// single-contact `fetch(localID:)` path auto-corrects the flag.
    public func setImageData(_ image: Data?, thumbnail: Data?, for localID: String) {
        lock.lock()
        defer { lock.unlock() }
        imageSidebandAccessCount += 1
        if image == nil && thumbnail == nil {
            imageSideband.removeValue(forKey: localID)
        } else {
            imageSideband[localID] = (image: image, thumbnail: thumbnail)
        }
    }
}
