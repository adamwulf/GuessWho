import Foundation
import UniformTypeIdentifiers
import GuessWhoLogging
import GuessWhoSync

/// Turns the item providers of a drop from Apple Mail into email header
/// metadata. No UI and no storage: callers decide what to keep.
///
/// Measured on macOS 27 (AppKit side), Mail puts one pasteboard item per
/// dragged message, carrying a file promise of the message as an `.eml`
/// (`com.apple.mail.email`) and a `message:%3C<Message-ID>%3E` URL. What a
/// Catalyst drop receives after the AppKit → `NSItemProvider` bridge is not
/// measured yet, so the reader copes with either the file or only the URL,
/// and logs each provider's registered types (never subjects or addresses).
///
/// Reading is two steps, because UIKit lets a drop's data be requested only
/// within `performDrop`, which is synchronous:
///
/// ```swift
/// let drop = MailDropReader.startLoading(providers)  // inside performDrop
/// Task { let messages = await MailDropReader.read(drop) }
/// ```
///
/// Main-actor isolated because `NSItemProvider` is not `Sendable` and drop
/// handlers hand providers over on the main actor. The load calls return at
/// once; their completion handlers are `@Sendable` and run on the provider's
/// own queue, which is where the file is read and parsed.
@MainActor
enum MailDropReader {
    nonisolated private static let log = GuessWhoLog.logger("app.mail-drop")

    /// Mail's type for a dragged message. Mail.app exports it (conforming to
    /// `public.email-message`), so `UTType(_:)` returns Mail's declaration
    /// wherever Mail is installed and nil elsewhere (iOS). Not
    /// `UTType(importedAs:)`: that is for a type this app declares under
    /// `UTImportedTypeDeclarations` in its own Info.plist, and the system
    /// logs a fault when that declaration is missing. Provider lookups use
    /// this identifier string, which matches either way.
    nonisolated private static let mailMessageTypeIdentifier = "com.apple.mail.email"

    /// Types a whole-profile drop target registers for.
    nonisolated static let acceptedTypes: [UTType] = [
        UTType(mailMessageTypeIdentifier),
        UTType.emailMessage,
        UTType.url,
    ].compactMap { $0 }

    /// The loads one drop started, one entry per provider in provider order.
    /// Holds only the pending results, never the providers, so it can cross
    /// to any isolation.
    struct PendingDrop: Sendable {
        fileprivate let messages: [PendingMessage]
    }

    /// True when at least one provider looks like a Mail message: it carries
    /// Mail's message type or `public.email-message` (a Finder `.eml` does
    /// too), or it carries a URL and is neither a file nor an image.
    ///
    /// A bare URL counts because Catalyst may expose only Mail's `message:`
    /// URL; `read` drops URLs of any other scheme. A file URL or an image
    /// does not count: `public.file-url` conforms to `public.url`, so
    /// without this a Finder file or a dragged web image would make the
    /// whole card accept a drop that adds nothing.
    static func canAccept(_ providers: [NSItemProvider]) -> Bool {
        providers.contains(where: isMailMessage)
    }

    private static func isMailMessage(_ provider: NSItemProvider) -> Bool {
        if [mailMessageTypeIdentifier, UTType.emailMessage.identifier]
            .contains(where: provider.hasItemConformingToTypeIdentifier) {
            return true
        }
        return provider.hasItemConformingToTypeIdentifier(UTType.url.identifier)
            && !provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
            && !provider.hasItemConformingToTypeIdentifier(UTType.image.identifier)
    }

    /// Starts every load for every provider (the `.eml`, the URL, and the
    /// plain text) and returns at once, so all providers load in parallel.
    ///
    /// Call this from `performDrop` (`UIDropInteractionDelegate`'s
    /// `dropInteraction(_:performDrop:)` or SwiftUI's
    /// `DropDelegate.performDrop(info:)`): UIKit allows a drop's data to be
    /// requested only within that method. Then await `read(_:)`.
    static func startLoading(_ providers: [NSItemProvider]) -> PendingDrop {
        PendingDrop(messages: providers.enumerated().map { index, provider in
            // At info so the hand test sees it: the default log floor is info.
            log.info("mail drop provider", [
                "index": index,
                "types": provider.registeredTypeIdentifiers.joined(separator: " "),
            ])
            return PendingMessage(
                file: loadFileHeaders(from: provider),
                url: loadURL(from: provider),
                plainText: loadPlainText(from: provider),
                suggestedSubject: suggestedSubject(provider.suggestedName)
            )
        })
    }

    /// Waits for the loads `startLoading(_:)` began. One
    /// `EmailMessageHeaders` per provider that yields a Message-ID, in
    /// provider order. Providers that yield none are skipped.
    nonisolated static func read(_ drop: PendingDrop) async -> [EmailMessageHeaders] {
        var messages: [EmailMessageHeaders] = []
        for (index, pending) in drop.messages.enumerated() {
            if let headers = await pending.headers() {
                messages.append(headers)
            } else {
                log.debug("mail drop provider has no Message-ID", ["index": index])
            }
        }
        return messages
    }

    // MARK: - Loads

    /// Loads the `.eml` once. Mail's type conforms to `public.email-message`,
    /// so a second identifier would ask Mail for the same file again.
    private static func loadFileHeaders(from provider: NSItemProvider) -> PendingValue<EmailMessageHeaders>? {
        guard let identifier = [mailMessageTypeIdentifier, UTType.emailMessage.identifier]
            .first(where: provider.hasItemConformingToTypeIdentifier)
        else { return nil }
        let pending = PendingValue<EmailMessageHeaders>()
        _ = provider.loadFileRepresentation(forTypeIdentifier: identifier) { @Sendable url, error in
            // The file is deleted when this handler returns, so it is read
            // and parsed here, off the main actor. The parser scans slices
            // of the mapped data without copying, so only the pages that
            // hold the header block are read from disk.
            guard let url else {
                log.debug("mail drop file unavailable", ["type": identifier, "error": errorSummary(error)])
                pending.complete(with: nil)
                return
            }
            do {
                let data = try Data(contentsOf: url, options: .alwaysMapped)
                pending.complete(with: EmailMessageHeaders.parse(data))
            } catch {
                log.debug("mail drop file unreadable", ["type": identifier, "error": errorSummary(error)])
                pending.complete(with: nil)
            }
        }
        return pending
    }

    private static func loadURL(from provider: NSItemProvider) -> PendingValue<URL>? {
        guard provider.canLoadObject(ofClass: URL.self) else { return nil }
        let pending = PendingValue<URL>()
        _ = provider.loadObject(ofClass: URL.self) { @Sendable url, error in
            if url == nil {
                log.debug("mail drop URL unavailable", ["error": errorSummary(error)])
            }
            pending.complete(with: url)
        }
        return pending
    }

    private static func loadPlainText(from provider: NSItemProvider) -> PendingValue<String>? {
        let identifier = UTType.utf8PlainText.identifier
        guard provider.hasItemConformingToTypeIdentifier(identifier) else { return nil }
        let pending = PendingValue<String>()
        _ = provider.loadDataRepresentation(forTypeIdentifier: identifier) { @Sendable data, _ in
            pending.complete(with: data.flatMap { nonEmpty(String(decoding: $0, as: UTF8.self)) })
        }
        return pending
    }

    /// Mail suggests `<subject>.eml` as the promised file's name.
    private static func suggestedSubject(_ suggestedName: String?) -> String? {
        guard var name = suggestedName else { return nil }
        if name.lowercased().hasSuffix(".eml") { name.removeLast(4) }
        return nonEmpty(name)
    }

    nonisolated private static func nonEmpty(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The error's domain and code only: a localized description can name
    /// the promised file, and Mail names it after the subject.
    nonisolated private static func errorSummary(_ error: (any Error)?) -> String {
        guard let error else { return "none" }
        let nsError = error as NSError
        return "\(nsError.domain)#\(nsError.code)"
    }
}

/// One provider's pending loads. The `.eml` is the source of truth; the
/// `message:` URL fills in a missing Message-ID, and the plain text or the
/// suggested file name fills in a missing subject.
private struct PendingMessage: Sendable {
    let file: PendingValue<EmailMessageHeaders>?
    let url: PendingValue<URL>?
    let plainText: PendingValue<String>?
    let suggestedSubject: String?

    func headers() async -> EmailMessageHeaders? {
        var headers = await file?.value ?? EmailMessageHeaders()
        if headers.messageID == nil, let url = await url?.value {
            headers.messageID = EmailMessageHeaders.messageID(fromMessageURL: url)
        }
        guard headers.messageID != nil else { return nil }
        if headers.subject == nil {
            headers.subject = await fallbackSubject()
        }
        return headers
    }

    /// Mail's plain text for the drag is the exact subject, so it comes
    /// first; the suggested file name can have characters replaced.
    private func fallbackSubject() async -> String? {
        if let text = await plainText?.value, !text.lowercased().hasPrefix("message:") {
            return text
        }
        return suggestedSubject
    }
}

/// A value that a load's completion handler delivers later. It is made
/// before the load starts, so the handler always has somewhere to put its
/// result, and the reader can await it from any isolation.
private struct PendingValue<Value: Sendable>: Sendable {
    private let stream: AsyncStream<Value>
    private let continuation: AsyncStream<Value>.Continuation

    init() {
        (stream, continuation) = AsyncStream.makeStream(of: Value.self)
    }

    /// Delivers the load's result, or nil when the load failed. The handler
    /// calls this exactly once on every path.
    func complete(with value: Value?) {
        if let value { continuation.yield(value) }
        continuation.finish()
    }

    /// The delivered value, or nil when the load failed. Read it once.
    var value: Value? {
        get async {
            for await value in stream { return value }
            return nil
        }
    }
}
