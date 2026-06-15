import Foundation
import GuessWhoSync

public final class InMemoryContactStore: ContactStoreProtocol {
    private let lock = NSLock()
    private var contactsByID: [String: Contact]

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
        return Array(contactsByID.values)
    }

    public func fetch(localID: String) throws -> Contact? {
        lock.lock()
        defer { lock.unlock() }
        return contactsByID[localID]
    }

    public func save(_ contact: Contact) throws {
        lock.lock()
        defer { lock.unlock() }
        contactsByID[contact.localID] = contact
    }
}
