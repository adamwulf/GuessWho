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

    @Test(arguments: ["https://example.com/article", "mailto:someone@example.com", "tel:+1-555-010-0199"])
    func plainLinkIsAccepted(_ string: String) throws {
        // A web, mailto:, or tel: link adds a value to the contact. Before
        // the drop only the URL's type is known, not its scheme, so a URL of
        // another scheme is accepted too and the reader drops it.
        let url = try #require(URL(string: string))
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
/// loads yield a Message-ID is a message; else an `http`, `https`, `mailto`,
/// or `tel` URL is a contact value; else the provider adds nothing.
///
/// Each provider is an in-process `NSItemProvider`: one made from an
/// `NSURL` is the shape of a URL-only drag item, and the two-phase tests add
/// Mail's plain text and an `.eml` file representation whose load the test
/// finishes when it chooses. They do not show which types Catalyst exposes
/// for a real drag from Mail or Safari, or how long Mail's file promise
/// takes; that is the hand test's log.
@MainActor
@Suite("Mail drop reading")
struct MailDropReaderReadTests {
    private static let mailMessageType = "com.apple.mail.email"

    private func read(_ urls: [String]) async throws -> MailDropReader.DroppedItems {
        let providers = try urls.map { string in
            NSItemProvider(object: try #require(URL(string: string)) as NSURL)
        }
        return await read(providers)
    }

    private func read(_ providers: [NSItemProvider]) async -> MailDropReader.DroppedItems {
        await MailDropReader.read(MailDropReader.startLoading(providers))
    }

    @Test
    func mailMessageURLIsAMessage() async throws {
        let items = try await read(["message:%3Cabc.123@example.com%3E"])
        #expect(items.messages.map(\.headers.messageID) == ["<abc.123@example.com>"])
        // No file to wait for later.
        #expect(items.messages.map(\.hasLateFile) == [false])
        #expect(items.contactValues.isEmpty)
    }

    // MARK: - Two phases

    /// An `.eml` that holds every header the reader keeps.
    private static func emlFile(messageID: String) throws -> URL {
        let text = [
            "Message-ID: <\(messageID)>",
            "From: Riya Suresh <riya@example.com>",
            "Subject: Quarterly plan",
            "Date: Wed, 30 Jul 2026 09:15:00 -0500",
            "",
            "Body.",
        ].joined(separator: "\r\n")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("eml")
        try Data(text.utf8).write(to: url)
        return url
    }

    /// A Mail-shaped provider: Mail's `message:` URL, its plain text (the
    /// subject), and an `.eml` file representation that `gate` holds until
    /// the test finishes it.
    private func mailProvider(messageID: String, subject: String, gate: FileGate) throws -> NSItemProvider {
        let url = try #require(URL(string: "message:%3C\(messageID)%3E"))
        let provider = NSItemProvider(object: url as NSURL)
        provider.registerDataRepresentation(forTypeIdentifier: UTType.utf8PlainText.identifier, visibility: .all) { completion in
            completion(Data(subject.utf8), nil)
            return nil
        }
        provider.registerFileRepresentation(
            forTypeIdentifier: Self.mailMessageType,
            fileOptions: [],
            visibility: .all
        ) { completion in
            gate.hold(completion)
            return nil
        }
        return provider
    }

    /// Phase 1: the `message:` URL gives the Message-ID and the plain text
    /// the subject, while the `.eml` has not arrived. Phase 2: the file's
    /// headers arrive when its load finishes.
    @Test(.timeLimit(.minutes(1)))
    func messageURLAndTextGiveTheMessageBeforeTheFile() async throws {
        let gate = FileGate()
        let provider = try mailProvider(messageID: "late.1@example.com", subject: "Quarterly plan", gate: gate)

        // The gate holds the file until after `read` returns, so a `read`
        // that waited for the file would never return (the time limit).
        let items = await read([provider])

        let message = try #require(items.messages.first)
        #expect(items.messages.count == 1)
        #expect(message.headers == EmailMessageHeaders(
            messageID: "<late.1@example.com>",
            subject: "Quarterly plan"
        ))
        #expect(message.hasLateFile)

        gate.finish(with: try Self.emlFile(messageID: "late.1@example.com"))
        let late = try #require(await message.lateFileHeaders())
        #expect(late.messageID == "<late.1@example.com>")
        #expect(late.fromName == "Riya Suresh")
        #expect(late.fromAddress == "riya@example.com")
        #expect(late.date != nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func aLateFileThatFailsGivesNoHeaders() async throws {
        let gate = FileGate()
        let provider = try mailProvider(messageID: "late.2@example.com", subject: "Plan", gate: gate)

        let items = await read([provider])

        let message = try #require(items.messages.first)
        #expect(message.headers.messageID == "<late.2@example.com>")
        gate.fail()
        #expect(await message.lateFileHeaders() == nil)
    }

    /// No `message:` URL (a Finder `.eml`): the file is the only source of
    /// the Message-ID, so `read` waits for it, and there is no late file.
    @Test(.timeLimit(.minutes(1)))
    func aProviderWithOnlyTheEmailFileWaitsForIt() async throws {
        let file = try Self.emlFile(messageID: "file.1@example.com")
        let provider = NSItemProvider()
        provider.registerFileRepresentation(
            forTypeIdentifier: Self.mailMessageType,
            fileOptions: [],
            visibility: .all
        ) { completion in
            // Finishes after `read` has started waiting.
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
                completion(file, false, nil)
            }
            return nil
        }

        let items = await read([provider])

        let message = try #require(items.messages.first)
        #expect(message.headers.messageID == "<file.1@example.com>")
        #expect(message.headers.fromName == "Riya Suresh")
        #expect(message.headers.fromAddress == "riya@example.com")
        #expect(message.headers.subject == "Quarterly plan")
        #expect(message.headers.date != nil)
        #expect(!message.hasLateFile)
    }

    @Test(arguments: [
        "https://example.com/article",
        "http://example.com/",
        "mailto:someone@example.com?subject=Hi",
        "tel:+1-555-010-0199;ext=2",
    ])
    func linkIsAContactValue(_ string: String) async throws {
        let items = try await read([string])
        #expect(items.messages.isEmpty)
        // Passed on whole: the repository reads the address or number.
        #expect(items.contactValues.map(\.absoluteString) == [string])
    }

    /// Includes a `message:` URL with no usable Message-ID: it is not a
    /// message, and `message` is not a contact-value scheme either.
    @Test
    func otherSchemesAreNeither() async throws {
        let items = try await read([
            "ftp://example.com/file.txt",
            "sms:+15550100199",
            "facetime:someone@example.com",
            "message:",
            "message:%3C%3E",
        ])
        #expect(items.messages.isEmpty)
        #expect(items.contactValues.isEmpty)
    }

    @Test
    func mixedDropKeepsProviderOrderInEachList() async throws {
        let items = try await read([
            "https://example.com/first",
            "message:%3Cone@example.com%3E",
            "mailto:someone@example.com",
            "http://example.org/second",
            "ftp://example.com/file.txt",
            "tel:5550100199",
            "message:%3Ctwo@example.com%3E",
        ])
        #expect(items.messages.map(\.headers.messageID) == ["<one@example.com>", "<two@example.com>"])
        #expect(items.contactValues.map(\.absoluteString) == [
            "https://example.com/first",
            "mailto:someone@example.com",
            "http://example.org/second",
            "tel:5550100199",
        ])
    }
}

/// Holds an `.eml` file load until the test finishes it. The provider asks
/// for the file on its own queue, possibly after the test finished the gate,
/// so whichever comes second delivers the result.
private final class FileGate: @unchecked Sendable {
    typealias Completion = (URL?, Bool, (any Error)?) -> Void

    private let lock = NSLock()
    private var completion: Completion?
    private var result: (url: URL?, error: (any Error)?)?

    /// The provider's load handler: keeps `completion` until the test
    /// finishes the gate.
    func hold(_ completion: @escaping Completion) {
        let ready = lock.withLock { () -> (url: URL?, error: (any Error)?)? in
            if let result { return result }
            self.completion = completion
            return nil
        }
        if let ready { completion(ready.url, false, ready.error) }
    }

    func finish(with url: URL) { deliver(url: url, error: nil) }

    func fail() { deliver(url: nil, error: CocoaError(.fileReadUnknown)) }

    private func deliver(url: URL?, error: (any Error)?) {
        let held = lock.withLock { () -> Completion? in
            result = (url, error)
            defer { completion = nil }
            return completion
        }
        held?(url, false, error)
    }
}
