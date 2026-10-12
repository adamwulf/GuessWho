import Foundation
import UniformTypeIdentifiers
import GuessWhoLogging
import GuessWhoSync

/// Turns the item providers of a drop onto the contact card into email header
/// metadata for Apple Mail messages, and into URLs that carry a value for the
/// contact's card (a website, an email address, or a phone number). No UI and
/// no storage: callers decide what to keep.
///
/// Measured on macOS 27 (AppKit side), Mail puts one pasteboard item per
/// dragged message, carrying a file promise of the message as an `.eml`
/// (`com.apple.mail.email`) and a `message:%3C<Message-ID>%3E` URL. On
/// Catalyst the provider registers both too, but in Adam's hand test the
/// `.eml` arrived about 29 s after the drop (likely a 30 s file-promise
/// timeout), while the row it built was right. So a message comes in two
/// phases:
///
/// 1. **Fast.** When the `message:` URL gives a Message-ID, `read` returns
///    the message at once with that Message-ID and a subject from Mail's
///    plain text, else from the suggested file name. It does not wait for
///    the `.eml`. A provider with no usable `message:` URL (a Finder `.eml`)
///    waits for its file: that is the only source of its Message-ID, and a
///    local file is fast.
/// 2. **Late.** The `.eml` of a fast message keeps loading. The caller
///    awaits `DroppedMessage.lateFileHeaders()` for the full headers (the
///    sender and the sent date) when they arrive.
///
/// The reader logs each provider's registered types and each finished load
/// (never subjects, addresses, or URLs).
///
/// Reading is two steps, because UIKit lets a drop's data be requested only
/// within `performDrop`, which is synchronous. Every load, the late `.eml`
/// too, starts there:
///
/// ```swift
/// let drop = MailDropReader.startLoading(providers)  // inside performDrop
/// Task { let items = await MailDropReader.read(drop) }
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
    /// `public.email-message`), so it is not declared on iOS. Kept as an
    /// identifier string, which provider lookups take: not
    /// `UTType(importedAs:)`, which is for a type this app declares under
    /// `UTImportedTypeDeclarations` in its own Info.plist, and the system
    /// logs a fault when that declaration is missing.
    nonisolated private static let mailMessageTypeIdentifier = "com.apple.mail.email"

    /// The loads one drop started, one entry per provider in provider order.
    /// Holds only the pending results, never the providers, so it can cross
    /// to any isolation.
    struct PendingDrop: Sendable {
        fileprivate let items: [PendingItem]
    }

    /// What one drop holds. Each list keeps provider order.
    struct DroppedItems: Sendable {
        /// One per provider whose loads yield a Message-ID: a `message:` URL,
        /// else the `.eml`.
        var messages: [DroppedMessage] = []
        /// One per other provider whose URL is `http`, `https`, `mailto`, or
        /// `tel`: `ContactsRepository.addContactValues(from:for:)` turns it
        /// into a website, email, or phone row.
        var contactValues: [URL] = []
    }

    /// One dropped message: the headers known when `read` returns, and, for
    /// a message read from its `message:` URL, the `.eml` still loading.
    struct DroppedMessage: Sendable {
        /// Always holds a Message-ID. From a `message:` URL, only the
        /// Message-ID and a subject (Mail's plain text, else the suggested
        /// file name); from an `.eml`, every header the file has.
        let headers: EmailMessageHeaders
        /// The `.eml` that `read` did not wait for. Nil when `headers` came
        /// from the file, or the provider has no file.
        fileprivate let lateFile: PendingValue<EmailMessageHeaders>?

        /// Whether `lateFileHeaders()` waits for an `.eml`.
        var hasLateFile: Bool { lateFile != nil }

        /// Waits for the `.eml` that `read` did not wait for, and returns
        /// its headers: the sender and the sent date that `headers` lacks.
        /// Nil when there is no such file, or its load failed. If the load
        /// never finishes, this never returns. Call it once, from one task:
        /// the file's headers go to one reader only.
        func lateFileHeaders() async -> EmailMessageHeaders? {
            await lateFile?.value
        }
    }

    /// True when at least one provider looks like a Mail message or a link:
    /// it carries Mail's message type or `public.email-message` (a Finder
    /// `.eml` does too), or it carries a URL and is neither a file nor an
    /// image.
    ///
    /// A bare URL counts because Catalyst may expose only Mail's `message:`
    /// URL, and because a web, `mailto:`, or `tel:` link adds a value to the
    /// contact. Only the type is known before the drop, not the scheme, so
    /// `read` drops a URL of any other scheme. A file URL or an image does
    /// not count:
    /// `public.file-url` conforms to `public.url`, so without this a Finder
    /// file or a dragged web image would make the whole card accept a drop
    /// that adds nothing.
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
    /// Call this from `UIDropInteractionDelegate`'s
    /// `dropInteraction(_:performDrop:)`: UIKit allows a drop's data to be
    /// requested only within that method. Then await `read(_:)`.
    static func startLoading(_ providers: [NSItemProvider]) -> PendingDrop {
        let start = ContinuousClock.now
        return PendingDrop(items: providers.enumerated().map { index, provider in
            // At info so the hand test sees it: the default log floor is info.
            log.info("mail drop provider", [
                "index": index,
                "types": provider.registeredTypeIdentifiers.joined(separator: " "),
            ])
            let load = LoadLog(index: index, start: start)
            return PendingItem(
                file: loadFileHeaders(from: provider, log: load),
                url: loadURL(from: provider, log: load),
                plainText: loadPlainText(from: provider, log: load),
                suggestedSubject: suggestedSubject(provider.suggestedName)
            )
        })
    }

    /// Waits for the loads `startLoading(_:)` began, except the `.eml` of a
    /// message whose `message:` URL gives its Message-ID. A provider whose
    /// loads yield a Message-ID is a message; else a provider whose URL is
    /// `http`, `https`, `mailto`, or `tel` is a contact value; else it is
    /// skipped.
    nonisolated static func read(_ drop: PendingDrop) async -> DroppedItems {
        var items = DroppedItems()
        for (index, pending) in drop.items.enumerated() {
            switch await pending.item() {
            case .message(let message):
                items.messages.append(message)
            case .contactValue(let url):
                items.contactValues.append(url)
            case nil:
                log.debug("mail drop provider has no Message-ID or contact value", ["index": index])
            }
        }
        return items
    }

    // MARK: - Loads

    /// Logs one line per finished load, at info so the hand test sees it:
    /// which provider, which load (`file`, `url`, or `text`), whether it
    /// gave a value, how many milliseconds after `startLoading` it finished,
    /// and the error as `domain#code`. Never a subject, an address, a URL,
    /// or a file name. It shows which load is slow, and whether Mail's
    /// `.eml` arrives at all.
    private struct LoadLog: Sendable {
        let index: Int
        let start: ContinuousClock.Instant

        func finished(_ kind: String, ok: Bool, error: (any Error)?) {
            let elapsed = ContinuousClock.now - start
            MailDropReader.log.info("mail drop load", [
                "index": index,
                "kind": kind,
                "ok": ok,
                "ms": Int((elapsed / .milliseconds(1)).rounded()),
                "error": MailDropReader.errorSummary(error),
            ])
        }
    }

    /// Loads the `.eml` once. Mail's type conforms to `public.email-message`,
    /// so a second identifier would ask Mail for the same file again.
    private static func loadFileHeaders(from provider: NSItemProvider, log: LoadLog) -> PendingValue<EmailMessageHeaders>? {
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
                log.finished("file", ok: false, error: error)
                pending.complete(with: nil)
                return
            }
            do {
                let data = try Data(contentsOf: url, options: .alwaysMapped)
                log.finished("file", ok: true, error: nil)
                pending.complete(with: EmailMessageHeaders.parse(data))
            } catch {
                log.finished("file", ok: false, error: error)
                pending.complete(with: nil)
            }
        }
        return pending
    }

    private static func loadURL(from provider: NSItemProvider, log: LoadLog) -> PendingValue<URL>? {
        guard provider.canLoadObject(ofClass: URL.self) else { return nil }
        let pending = PendingValue<URL>()
        _ = provider.loadObject(ofClass: URL.self) { @Sendable url, error in
            log.finished("url", ok: url != nil, error: error)
            pending.complete(with: url)
        }
        return pending
    }

    private static func loadPlainText(from provider: NSItemProvider, log: LoadLog) -> PendingValue<String>? {
        let identifier = UTType.utf8PlainText.identifier
        guard provider.hasItemConformingToTypeIdentifier(identifier) else { return nil }
        let pending = PendingValue<String>()
        _ = provider.loadDataRepresentation(forTypeIdentifier: identifier) { @Sendable data, error in
            log.finished("text", ok: data != nil, error: error)
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

/// What one provider of a drop is.
private enum DroppedItem {
    case message(MailDropReader.DroppedMessage)
    case contactValue(URL)
}

/// One provider's pending loads, started together in `performDrop`.
///
/// A message comes first from its `message:` URL: when that gives a
/// Message-ID, the message does not wait for the `.eml` (on Catalyst Mail's
/// file promise took about 29 s); the plain text or the suggested file name
/// gives its subject, and the `.eml` goes with it as the late file. Else the
/// `.eml` is the only source of the Message-ID (a Finder `.eml` file), so
/// the message waits for it. A provider with no Message-ID is a contact
/// value when its URL is one.
private struct PendingItem: Sendable {
    let file: PendingValue<EmailMessageHeaders>?
    let url: PendingValue<URL>?
    let plainText: PendingValue<String>?
    let suggestedSubject: String?

    func item() async -> DroppedItem? {
        let loadedURL = await url?.value
        if let loadedURL, let messageID = EmailMessageHeaders.messageID(fromMessageURL: loadedURL) {
            var headers = EmailMessageHeaders()
            headers.messageID = messageID
            headers.subject = await fallbackSubject()
            return .message(MailDropReader.DroppedMessage(headers: headers, lateFile: file))
        }
        var headers = await file?.value ?? EmailMessageHeaders()
        if headers.messageID != nil {
            if headers.subject == nil {
                headers.subject = await fallbackSubject()
            }
            return .message(MailDropReader.DroppedMessage(headers: headers, lateFile: nil))
        }
        if let loadedURL, Self.isContactValue(loadedURL) {
            return .contactValue(loadedURL)
        }
        return nil
    }

    /// An `http`, `https`, `mailto`, or `tel` scheme, in any case: the
    /// schemes `ContactsRepository.addContactValues(from:for:)` reads. That
    /// method still skips a URL that holds no usable value, such as a
    /// `mailto:` with no address.
    private static func isContactValue(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return ["http", "https", "mailto", "tel"].contains(scheme)
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
