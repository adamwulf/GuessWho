import Foundation
import MailKit
import os

/// Looks at each newly downloaded message's sender, colors mail from
/// highlighted contacts blue, and journals one metadata-only entry per message
/// from any known contact for the app to store.
///
/// Fail-open: when the cache or the journal can't be used, the message is
/// left exactly as Mail delivered it (no decision) and the failure is only
/// logged. Headers only — the body is never requested or read.
///
/// Not main-actor bound: Mail calls `decideAction` from its own queues, and
/// all state here is immutable and `Sendable`.
final class MessageActionHandler: NSObject, MEMessageActionHandler, Sendable {

    static let shared = MessageActionHandler(
        contactCache: MailExtensionStorage.contactCache,
        journal: MailExtensionStorage.journal)

    private static let log = Logger.mailExtension("message-action")

    private let contactCache: MailContactCacheStore?
    private let journal: MailIncomingJournal?

    init(contactCache: MailContactCacheStore?, journal: MailIncomingJournal?) {
        self.contactCache = contactCache
        self.journal = journal
        super.init()
    }

    /// Mail's first call may carry only a subset of headers; asking for
    /// `Message-ID` up front means the journal entry has its de-duplication
    /// key without ever asking for the body (`invokeAgainWithBody`).
    var requiredHeaders: [String] { ["message-id"] }

    func decideAction(for message: MEMessage, completionHandler: @escaping (MEMessageActionDecision?) -> Void) {
        completionHandler(decision(for: message))
    }

    private func decision(for message: MEMessage) -> MEMessageActionDecision? {
        guard message.state == .received,
              let sender = Self.normalizedSender(of: message)
        else { return nil }

        guard let contactCache, let journal else {
            Self.log.error("shared container unavailable; leaving message unchanged")
            return nil
        }

        let contents: MailContactCacheContents
        do {
            guard let read = try contactCache.read() else { return nil }
            contents = read
        } catch {
            Self.log.error("contact cache read failed; leaving message unchanged: \(LoggedError.fingerprint(error), privacy: .public)")
            return nil
        }
        guard contents.isKnown(address: sender) else { return nil }

        // Journal every known sender — even from a newer-format cache, whose
        // address index is all this build can read.
        do {
            try record(message, sender: sender, in: journal)
        } catch {
            Self.log.error("journal append failed; leaving message unchanged: \(LoggedError.fingerprint(error), privacy: .public)")
            return nil
        }

        // A newer-format cache yields no summaries, so the message is left
        // uncolored rather than guessed at.
        guard contents.summaries(forAddress: sender).contains(where: \.isHighlighted) else { return nil }
        return .action(.setBackgroundColor(.blue))
    }

    /// Appends the message's metadata. A message with no usable Message-ID has
    /// no de-duplication key, so it isn't journaled; neither is one the
    /// journal has no room for. Neither is a failure — the highlight still
    /// applies.
    private func record(_ message: MEMessage, sender: String, in journal: MailIncomingJournal) throws {
        guard let messageID = Self.messageIDHeader(of: message).flatMap(MailMessageID.normalize) else {
            Self.log.notice("known sender but no usable Message-ID; not journaled")
            return
        }
        let subject = message.subject.trimmingCharacters(in: .whitespacesAndNewlines)
        let entry = MailIncomingMessage(
            sender: sender,
            subject: subject.isEmpty ? nil : subject,
            receivedAt: message.__dateReceived ?? Date(),
            messageID: messageID,
            // Best effort only: the message:// scheme is undocumented and may
            // not resolve (see MailMessageID.mailDeepLink). A nil link never
            // blocks the entry.
            messageURL: MailMessageID.mailDeepLink(for: messageID))
        if try journal.append(entry) == .droppedForCapacity {
            Self.log.notice("journal full of claimed entries; message not journaled")
        }
    }

    private static func normalizedSender(of message: MEMessage) -> String? {
        let from = message.fromAddress
        return from.addressString.flatMap(MailAddressNormalizer.normalize)
            ?? MailAddressNormalizer.normalize(from.rawString)
    }

    /// MailKit documents that it lowercases `requiredHeaders` names before
    /// fetching them, but not the key case of `MEMessage.headers`, so match
    /// either way.
    private static func messageIDHeader(of message: MEMessage) -> String? {
        guard let headers = message.headers else { return nil }
        let values = headers["message-id"]
            ?? headers.first(where: { $0.key.caseInsensitiveCompare("message-id") == .orderedSame })?.value
        return values?.first
    }
}
