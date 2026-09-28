import Foundation

/// One incoming message from a known sender, as the Mail extension records it
/// for the app. Metadata only — never any part of the message body.
struct MailIncomingMessage: Codable, Sendable, Equatable {
    /// The entry format this build writes and the newest it reads. Entries
    /// with a newer version are left in the journal untouched (see
    /// `MailIncomingJournal`), so an older reader never destroys them.
    static let currentVersion = 1

    var version: Int
    /// Normalized (`MailAddressNormalizer`) sender address.
    var sender: String
    var subject: String?
    var receivedAt: Date
    /// Canonical `<…>` Message-ID (`MailMessageID.normalize(_:)`); the
    /// journal's de-duplication key.
    var messageID: String
    /// Best-effort `message://` link (`MailMessageID.mailDeepLink(for:)`).
    /// Undocumented Apple Mail scheme — may be nil, and may not open even
    /// when present.
    var messageURL: URL?

    init(sender: String, subject: String?, receivedAt: Date, messageID: String, messageURL: URL?) {
        self.version = Self.currentVersion
        self.sender = sender
        self.subject = subject
        self.receivedAt = receivedAt
        self.messageID = messageID
        self.messageURL = messageURL
    }
}
