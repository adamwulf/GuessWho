import Foundation
import Testing
import UniformTypeIdentifiers
@testable import GuessWho

/// Which drags the whole-card email drop target accepts. Mail messages and
/// Mail's bare `message:` URL count; a Finder file or a dragged image must
/// not, so the card does not take a drop that adds nothing.
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
        // Accepted: before the drop only the URL's type is known, not its
        // scheme. The reader finds no Message-ID in it, so the drop adds
        // nothing.
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
