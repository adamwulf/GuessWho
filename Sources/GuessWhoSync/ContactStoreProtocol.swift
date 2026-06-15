import Foundation

public protocol ContactStoreProtocol {
    func fetchAll() throws -> [Contact]
    func fetch(localID: String) throws -> Contact?
    func save(_ contact: Contact) throws
}
