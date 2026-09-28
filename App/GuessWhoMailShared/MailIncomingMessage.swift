import Foundation

/// One incoming message from a known sender, as the Mail extension records it
/// for the app. Metadata only — never any part of the message body.
///
/// Every text field comes from the message's headers, which the sender
/// controls, so each is bounded in UTF-8 bytes: `init` clips the subject and
/// drops an over-long link, and `MailIncomingJournal.append` rejects an
/// over-long sender or Message-ID.
struct MailIncomingMessage: Codable, Sendable, Equatable {
    /// The entry format this build writes and the newest it reads. Bump it
    /// only for a breaking shape change (a field renamed, retyped, or
    /// removed); an added optional field is not breaking, because decoders
    /// ignore unknown keys and claim edits carry them through. Entries with a
    /// newer version are never claimed or rewritten by an older build (see
    /// `MailIncomingJournal`), though retention may evict them like any other
    /// unclaimed line.
    static let currentVersion = 1

    /// The longest subject kept, in UTF-8 bytes. A longer subject is cut at
    /// the last whole character (grapheme cluster) that fits, so the stored
    /// text is always valid UTF-8 and never splits a combining sequence.
    static let maximumSubjectUTF8Length = 1_024
    /// The longest `messageURL` kept, in UTF-8 bytes. A link built from a
    /// maximum-length Message-ID, fully percent-encoded, still fits.
    static let maximumMessageURLUTF8Length = 4 * 1_024

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
        self.subject = subject.flatMap { Self.clipped($0, toUTF8Length: Self.maximumSubjectUTF8Length) }
        self.receivedAt = receivedAt
        self.messageID = messageID
        self.messageURL = messageURL.flatMap {
            $0.absoluteString.utf8.count <= Self.maximumMessageURLUTF8Length ? $0 : nil
        }
    }

    /// `text` cut to at most `limit` UTF-8 bytes at a character boundary, or
    /// nil when not even its first character fits.
    static func clipped(_ text: String, toUTF8Length limit: Int) -> String? {
        guard text.utf8.count > limit else { return text }
        var byteCount = 0
        var end = text.startIndex
        for character in text {
            let characterBytes = character.utf8.count
            guard byteCount + characterBytes <= limit else { break }
            byteCount += characterBytes
            end = text.index(after: end)
        }
        return end == text.startIndex ? nil : String(text[..<end])
    }
}
