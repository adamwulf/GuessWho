import Foundation

public protocol ContactStoreProtocol: Actor {
    // Each method is `async throws` so adapter implementations can
    // bridge the underlying synchronous, XPC-blocking Contacts framework
    // calls onto a dedicated `.userInitiated` queue via a continuation
    // without holding the actor's executor thread. A plain `throws`
    // shape would block the actor through the duration of the CN call
    // and reintroduce the priority inversion the bridge is here to fix.
    func fetchAll() async throws -> [Contact]
    func fetch(localID: String) async throws -> Contact?
    func save(_ contact: Contact) async throws
    func delete(localID: String) async throws

    // Image bytes are loaded on demand so bulk fetches don't pay the cost.
    // - Contact does not exist          → throws ContactStoreError.contactNotFound
    // - Contact exists, no image bytes  → returns nil
    // - Contact exists, bytes available → returns the bytes
    func loadImageData(localID: String) async throws -> Data?
    func loadThumbnailImageData(localID: String) async throws -> Data?
}
