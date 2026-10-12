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

    /// True when at least one provider looks like a Mail message. A bare URL
    /// counts because Catalyst may expose only Mail's `message:` URL; `read`
    /// drops URLs of any other scheme.
    static func canAccept(_ providers: [NSItemProvider]) -> Bool {
        let identifiers = [mailMessageTypeIdentifier, UTType.emailMessage.identifier, UTType.url.identifier]
        return providers.contains { provider in
            identifiers.contains(where: provider.hasItemConformingToTypeIdentifier)
        }
    }

    /// One `EmailMessageHeaders` per provider that yields a Message-ID, in
    /// provider order. Providers that yield none are skipped.
    static func read(_ providers: [NSItemProvider]) async -> [EmailMessageHeaders] {
        var messages: [EmailMessageHeaders] = []
        for (index, provider) in providers.enumerated() {
            // At info so the hand test sees it: the default log floor is info.
            log.info("mail drop provider", [
                "index": index,
                "types": provider.registeredTypeIdentifiers.joined(separator: " "),
            ])
            if let headers = await headers(from: provider) {
                messages.append(headers)
            } else {
                log.debug("mail drop provider has no Message-ID", ["index": index])
            }
        }
        return messages
    }

    /// The parsed `.eml` when the provider has one. Mail's `message:` URL
    /// supplies the Message-ID when the file is missing or has none, and the
    /// drag's plain text or suggested file name stands in for a missing
    /// subject.
    private static func headers(from provider: NSItemProvider) async -> EmailMessageHeaders? {
        var headers = await fileHeaders(from: provider) ?? EmailMessageHeaders()
        if headers.messageID == nil {
            headers.messageID = await messageURLMessageID(from: provider)
        }
        guard headers.messageID != nil else { return nil }
        if headers.subject == nil {
            headers.subject = await fallbackSubject(from: provider)
        }
        return headers
    }

    // MARK: - The .eml file

    private static func fileHeaders(from provider: NSItemProvider) async -> EmailMessageHeaders? {
        for identifier in [mailMessageTypeIdentifier, UTType.emailMessage.identifier]
        where provider.hasItemConformingToTypeIdentifier(identifier) {
            if let headers = await loadFileHeaders(from: provider, typeIdentifier: identifier) {
                return headers
            }
        }
        return nil
    }

    private static func loadFileHeaders(
        from provider: NSItemProvider,
        typeIdentifier: String
    ) async -> EmailMessageHeaders? {
        await withCheckedContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { @Sendable url, error in
                // The file is deleted when this handler returns, so it is read
                // and parsed here, off the main actor. The parser scans slices
                // of the mapped data without copying, so only the pages that
                // hold the header block are read from disk.
                guard let url else {
                    log.debug("mail drop file unavailable", ["type": typeIdentifier, "error": errorSummary(error)])
                    continuation.resume(returning: nil)
                    return
                }
                do {
                    let data = try Data(contentsOf: url, options: .alwaysMapped)
                    continuation.resume(returning: EmailMessageHeaders.parse(data))
                } catch {
                    log.debug("mail drop file unreadable", ["type": typeIdentifier, "error": errorSummary(error)])
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    // MARK: - The message: URL

    private static func messageURLMessageID(from provider: NSItemProvider) async -> String? {
        guard provider.canLoadObject(ofClass: URL.self) else { return nil }
        let url: URL? = await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { @Sendable url, error in
                if url == nil {
                    log.debug("mail drop URL unavailable", ["error": errorSummary(error)])
                }
                continuation.resume(returning: url)
            }
        }
        return url.flatMap(messageID(fromMessageURL:))
    }

    /// The Message-ID in a Mail `message:` URL (`message:%3C<id>%3E`, or the
    /// `message://` spelling), percent-decoded. Nil for any other scheme.
    nonisolated static func messageID(fromMessageURL url: URL) -> String? {
        guard let scheme = url.scheme, scheme.lowercased() == "message" else { return nil }
        var encoded = url.absoluteString.dropFirst(scheme.count + 1)
        if encoded.hasPrefix("//") { encoded = encoded.dropFirst(2) }
        guard let decoded = encoded.removingPercentEncoding?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !decoded.isEmpty
        else { return nil }
        return decoded
    }

    // MARK: - Subject fallback

    /// Mail's plain text for the drag is the exact subject, so it comes
    /// first; the suggested file name (`<subject>.eml`) is the fallback.
    private static func fallbackSubject(from provider: NSItemProvider) async -> String? {
        if let text = await plainText(from: provider),
           !text.lowercased().hasPrefix("message:") {
            return text
        }
        guard var name = provider.suggestedName else { return nil }
        if name.lowercased().hasSuffix(".eml") { name.removeLast(4) }
        return nonEmpty(name)
    }

    private static func plainText(from provider: NSItemProvider) async -> String? {
        let identifier = UTType.utf8PlainText.identifier
        guard provider.hasItemConformingToTypeIdentifier(identifier) else { return nil }
        return await withCheckedContinuation { continuation in
            _ = provider.loadDataRepresentation(forTypeIdentifier: identifier) { @Sendable data, _ in
                continuation.resume(returning: data.flatMap { nonEmpty(String(decoding: $0, as: UTF8.self)) })
            }
        }
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
