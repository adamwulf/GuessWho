import Foundation

/// One incoming message from a known sender, as the Mail extension records it
/// for the app. Metadata only — never any part of the message body.
///
/// Every text field comes from the message's headers, which the sender
/// controls, so each is bounded: `init` clips the subject and drops an
/// over-long link, and `MailIncomingJournal.append` rejects an over-long
/// sender or Message-ID.
struct MailIncomingMessage: Codable, Sendable, Equatable {
    /// The entry format this build writes and the newest it reads. Bump it
    /// only for a breaking shape change (a field renamed, retyped, or
    /// removed); an added optional field is not breaking, because decoders
    /// ignore unknown keys and the journal carries them through rewrites.
    /// Entries with a newer version are left in the journal untouched (see
    /// `MailIncomingJournal`), so an older reader never destroys them.
    static let currentVersion = 1

    /// The longest subject kept, in characters.
    static let maximumSubjectLength = 512
    /// The longest `messageURL` kept, in UTF-8 bytes. A link built from a
    /// maximum-length Message-ID, fully percent-encoded, still fits.
    static let maximumMessageURLLength = 4 * 1024

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
        self.subject = subject.map { String($0.prefix(Self.maximumSubjectLength)) }
        self.receivedAt = receivedAt
        self.messageID = messageID
        self.messageURL = messageURL.flatMap {
            $0.absoluteString.utf8.count <= Self.maximumMessageURLLength ? $0 : nil
        }
    }
}
