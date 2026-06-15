import Foundation

public protocol ContactStoreProtocol {
    func fetchAll() throws -> [Contact]
    func fetch(localID: String) throws -> Contact?
    func save(_ contact: Contact) throws

    // Image bytes are loaded on demand so bulk fetches don't pay the cost.
    // - Contact does not exist          → throws ContactStoreError.contactNotFound
    // - Contact exists, no image bytes  → returns nil
    // - Contact exists, bytes available → returns the bytes
    func loadImageData(localID: String) throws -> Data?
    func loadThumbnailImageData(localID: String) throws -> Data?
}
