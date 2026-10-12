import Foundation
import Testing
import UniformTypeIdentifiers
import GuessWhoSync
@testable import GuessWho

/// Which drags the whole-card drop target accepts. Mail messages and a bare
/// URL (Mail's `message:` URL, or a web link) count; a Finder file or a
/// dragged image must not, so the card does not take a drop that adds nothing.
@MainActor
@Suite("Mail drop acceptance")
struct MailDropReaderTests {
    /// A provider that registers data for each of `typeIdentifiers`.
    private func provider(_ typeIdentifiers: [String]) -> NSItemProvider {
        let provider = NSItemProvider()
        for identifier in typeIdentifiers {
            provider.registerDataRepresentation(forTypeIdentifier: identifier, visibility: .all) { completion in
                completion(Data(), nil)
                return nil
            }
        }
        return provider
    }

    private func urlProvider(_ url: URL) -> NSItemProvider {
        NSItemProvider(object: url as NSURL)
    }

    @Test
    func mailMessageTypesAreAccepted() {
        #expect(MailDropReader.canAccept([provider(["com.apple.mail.email"])]))
        #expect(MailDropReader.canAccept([provider([UTType.emailMessage.identifier])]))
    }

    @Test
    func finderEmailFileIsAccepted() {
        let eml = provider([UTType.emailMessage.identifier, UTType.fileURL.identifier])
        #expect(MailDropReader.canAccept([eml]))
    }

    @Test
    func mailMessageURLAloneIsAccepted() throws {
        let url = try #require(URL(string: "message:%3Cabc.123@example.com%3E"))
        #expect(MailDropReader.canAccept([urlProvider(url)]))
    }

    @Test
    func fileAndImageDragsAreRefused() throws {
        let fileURL = URL(fileURLWithPath: "/tmp/photo.jpg")
        #expect(!MailDropReader.canAccept([urlProvider(fileURL)]))
        #expect(!MailDropReader.canAccept([provider([UTType.fileURL.identifier, UTType.pdf.identifier])]))
        #expect(!MailDropReader.canAccept([provider([UTType.jpeg.identifier])]))

        let imageURL = try #require(URL(string: "https://example.com/photo.jpg"))
        let webImage = urlProvider(imageURL)
        webImage.registerDataRepresentation(forTypeIdentifier: UTType.jpeg.identifier, visibility: .all) { completion in
            completion(Data(), nil)
            return nil
        }
        #expect(!MailDropReader.canAccept([webImage]))
    }

    @Test
    func plainWebLinkIsAccepted() throws {
        // A web link adds a website to the contact. Before the drop only the
        // URL's type is known, not its scheme, so a URL of another scheme is
        // accepted too and the reader drops it.
        let url = try #require(URL(string: "https://example.com/article"))
        #expect(MailDropReader.canAccept([urlProvider(url)]))
    }

    @Test
    func oneMailMessageAmongOtherItemsIsEnough() throws {
        let image = provider([UTType.jpeg.identifier])
        let mail = provider(["com.apple.mail.email"])
        #expect(MailDropReader.canAccept([image, mail]))
        #expect(!MailDropReader.canAccept([image]))
        #expect(!MailDropReader.canAccept([]))
    }
}

/// What a drop becomes, through the same two steps a drop takes:
/// `startLoading` (as inside `performDrop`), then `read`. A provider whose
/// loads yield a Message-ID is a message; else an `http` or `https` URL is a
/// web address; else the provider adds nothing.
///
/// Each provider is an in-process `NSItemProvider` made from an `NSURL`, the
/// shape of a URL-only drag item. It does not show which types Catalyst
/// exposes for a real drag from Mail or Safari; that is the hand test's log.
@MainActor
@Suite("Mail drop reading")
struct MailDropReaderReadTests {
    private func read(_ urls: [String]) async throws -> MailDropReader.DroppedItems {
        let providers = try urls.map { string in
            NSItemProvider(object: try #require(URL(string: string)) as NSURL)
        }
        return await MailDropReader.read(MailDropReader.startLoading(providers))
    }

    @Test
    func mailMessageURLIsAMessage() async throws {
        let items = try await read(["message:%3Cabc.123@example.com%3E"])
        #expect(items.messages.map(\.messageID) == ["<abc.123@example.com>"])
        #expect(items.webAddresses.isEmpty)
    }

    @Test
    func httpsLinkIsAWebAddress() async throws {
        let items = try await read(["https://example.com/article"])
        #expect(items.messages.isEmpty)
        #expect(items.webAddresses.map(\.absoluteString) == ["https://example.com/article"])
    }

    @Test
    func httpLinkIsAWebAddress() async throws {
        let items = try await read(["http://example.com/"])
        #expect(items.messages.isEmpty)
        #expect(items.webAddresses.map(\.absoluteString) == ["http://example.com/"])
    }

    @Test
    func otherSchemesAreNeither() async throws {
        let items = try await read(["mailto:someone@example.com", "ftp://example.com/file.txt"])
        #expect(items == MailDropReader.DroppedItems())
    }

    @Test
    func mixedDropKeepsProviderOrderInEachList() async throws {
        let items = try await read([
            "https://example.com/first",
            "message:%3Cone@example.com%3E",
            "mailto:someone@example.com",
            "http://example.org/second",
            "ftp://example.com/file.txt",
            "message:%3Ctwo@example.com%3E",
        ])
        #expect(items.messages.map(\.messageID) == ["<one@example.com>", "<two@example.com>"])
        #expect(items.webAddresses.map(\.absoluteString) == [
            "https://example.com/first",
            "http://example.org/second",
        ])
    }
}
