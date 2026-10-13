import Foundation

/// One email message the user saved on a contact by dropping or starring it — the
/// contact card's "Highlighted Emails" section.
///
/// Unlike `MailActivity` (mail the Mail extension finds automatically), a
/// highlighted email is user-curated: its sender is ANY address, not
/// necessarily the contact's, so it never moves `lastInteracted`; the user
/// chose to keep it, so there is no retention limit; and the user can remove
/// it, so removal is a tombstone.
///
/// Stored as ONE additive cell on the contact's sidecar envelope, keyed
/// `highlightedEmail:<id>` (see `cellKey`). `GuessWhoSync.fields(at:)` skips
/// that key prefix explicitly, so the field-instance reads built on it (notes,
/// custom fields, the CLI/MCP field tools) never see these cells. An older
/// build that has never heard of them carries them through its raw-cell
/// read-modify-write untouched (docs/sidecar-compatibility.md).
///
/// `id` is DETERMINISTIC: derived from the normalized RFC 5322 Message-ID, so
/// the same email dropped twice on one contact lands on one cell.
///
/// The synced format and write rules: docs/highlighted-emails.md.
public struct HighlightedEmail: Hashable, Sendable, Identifiable {
    /// Stable identity derived from `messageID` (see `emailID(forMessageID:)`).
    public let id: UUID
    /// The message's RFC 5322 Message-ID in normalized form, by the same
    /// rules as `MailActivity` (no angle brackets, no whitespace, domain
    /// part lowercased).
    public let messageID: String
    public let subject: String?
    /// The display name from the From header.
    public let senderName: String?
    /// The address from the From header.
    public let senderAddress: String?
    /// The message's Date header, at the sidecar's stored precision.
    public let sentAt: Date?
    /// When the user dropped or starred the message on the contact, at the sidecar's
    /// stored precision.
    public let highlightedAt: Date

    /// Builds a highlighted email for the message identified by `messageID`.
    /// Returns nil when `messageID` is empty after normalization, because the
    /// email would have no stable identity to deduplicate on. The other
    /// strings are trimmed of surrounding whitespace, and an empty one is
    /// treated as nil. Both dates are rounded to the stored precision, so a
    /// value read back compares equal to the one written.
    public init?(
        messageID: String,
        subject: String?,
        senderName: String?,
        senderAddress: String?,
        sentAt: Date?,
        highlightedAt: Date
    ) {
        guard let normalized = MailActivity.normalizedMessageID(messageID) else { return nil }
        self.init(
            id: Self.emailID(forNormalizedMessageID: normalized),
            messageID: normalized,
            subject: Self.trimmedNonEmpty(subject),
            senderName: Self.trimmedNonEmpty(senderName),
            senderAddress: Self.trimmedNonEmpty(senderAddress),
            sentAt: sentAt.map(MailActivity.storedPrecision),
            highlightedAt: MailActivity.storedPrecision(highlightedAt)
        )
    }

    /// Builds the highlighted email for a dropped message's `headers`,
    /// highlighted at `highlightedAt`: the From display name and address
    /// become the sender, and the Date header becomes `sentAt`. Returns nil
    /// when the headers have no Message-ID, or one that is empty after
    /// normalization.
    public init?(headers: EmailMessageHeaders, highlightedAt: Date) {
        guard let messageID = headers.messageID else { return nil }
        self.init(
            messageID: messageID,
            subject: headers.subject,
            senderName: headers.fromName,
            senderAddress: headers.fromAddress,
            sentAt: headers.date,
            highlightedAt: highlightedAt
        )
    }

    /// Builds a highlighted email from an automatic message. Its received date is the
    /// best available message date; the Mail journal has no Date header.
    public init?(activity: MailActivity, highlightedAt: Date) {
        self.init(
            messageID: activity.messageID,
            subject: activity.subject,
            senderName: nil,
            senderAddress: activity.senderAddress,
            sentAt: activity.receivedAt,
            highlightedAt: highlightedAt
        )
    }

    /// Memberwise init for decode; takes already-normalized values.
    init(
        id: UUID,
        messageID: String,
        subject: String?,
        senderName: String?,
        senderAddress: String?,
        sentAt: Date?,
        highlightedAt: Date
    ) {
        self.id = id
        self.messageID = messageID
        self.subject = subject
        self.senderName = senderName
        self.senderAddress = senderAddress
        self.sentAt = sentAt
        self.highlightedAt = highlightedAt
    }

    /// The date the email sorts by: when it was sent, or when it was
    /// highlighted for a message with no Date header.
    public var sortDate: Date { sentAt ?? highlightedAt }

    /// The one highlighted-email order: newer `sortDate` first, ties broken
    /// by the `id` string so every device ranks the same set identically.
    /// `GuessWhoSync.highlightedEmails(at:)` returns this order.
    public func isNewer(than other: HighlightedEmail) -> Bool {
        if sortDate != other.sortDate { return sortDate > other.sortDate }
        return id.uuidString < other.id.uuidString
    }

    /// The deterministic id for `messageID`, or nil when it is empty after
    /// normalization. Any spelling of the same Message-ID (with or without
    /// angle brackets, folded whitespace, domain case) yields the same id.
    public static func emailID(forMessageID messageID: String) -> UUID? {
        MailActivity.normalizedMessageID(messageID).map(emailID(forNormalizedMessageID:))
    }

    /// SHA-256 over `"highlighted-email\n" + messageID`, formatted as an RFC
    /// 4122 UUID. The namespace differs from `MailActivity`'s, so one message
    /// that is both a mail activity and a highlighted email has two ids.
    private static func emailID(forNormalizedMessageID messageID: String) -> UUID {
        MailActivity.messageUUID(namespace: "highlighted-email", normalizedMessageID: messageID)
    }

    private static func trimmedNonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

// MARK: - Cell encoding

extension HighlightedEmail {
    // Stable on-disk spellings — part of the synced format, never change them.
    static let cellKeyPrefix = "highlightedEmail:"
    static let messageIDKey = "messageID"
    static let highlightedAtKey = "highlightedAt"
    static let subjectKey = "subject"
    static let senderNameKey = "senderName"
    static let senderKey = "sender"
    static let sentAtKey = "sentAt"

    /// The fixed cell key the email with `id` occupies on the contact envelope.
    static func cellKey(for id: UUID) -> String { cellKeyPrefix + id.uuidString.lowercased() }

    /// The fixed cell key this email occupies on the contact envelope.
    var cellKey: String { Self.cellKey(for: id) }

    /// Whether `cellKey` names a highlighted-email cell. Generic cell readers
    /// use this to keep these cells out of their projections.
    static func isCellKey(_ cellKey: String) -> Bool {
        cellKey.hasPrefix(cellKeyPrefix)
    }

    /// The cell's opaque value object for a first drop (or a revive).
    /// Optional members are omitted when nil.
    var cellValue: JSONValue { cellValue(overlaying: [:]) }

    /// The cell value for a repeat drop onto an existing live value object:
    /// this build's keys are written over `existing`, every other key (one a
    /// newer build added) is kept, an existing optional value is kept when
    /// this drop has none, and an existing `highlightedAt` is always kept —
    /// the email was highlighted when it was FIRST dropped.
    func cellValue(overlaying existing: [String: JSONValue]) -> JSONValue {
        var object = existing
        object[Self.messageIDKey] = .string(messageID)
        if object[Self.highlightedAtKey] == nil {
            object[Self.highlightedAtKey] = .string(SidecarISO8601.string(from: highlightedAt))
        }
        if let subject { object[Self.subjectKey] = .string(subject) }
        if let senderName { object[Self.senderNameKey] = .string(senderName) }
        if let senderAddress { object[Self.senderKey] = .string(senderAddress) }
        if let sentAt { object[Self.sentAtKey] = .string(SidecarISO8601.string(from: sentAt)) }
        return .object(object)
    }

    /// Decodes one envelope cell, or nil when `cellKey` is not a
    /// highlighted-email key, or the value is not an object with a string
    /// `messageID` and a valid `highlightedAt`. An optional member that is
    /// not a string (or, for `sentAt`, not a valid date) reads as nil. Nil
    /// only hides the email from reads; the cell stays in the envelope.
    /// Soft-deleted cells decode like live ones; callers filter.
    init?(cellKey: String, cell: SidecarCell) {
        guard Self.isCellKey(cellKey),
              let id = UUID(uuidString: String(cellKey.dropFirst(Self.cellKeyPrefix.count))),
              case .object(let object) = cell.value,
              case .string(let messageID) = object[Self.messageIDKey] ?? .null,
              case .string(let highlightedRaw) = object[Self.highlightedAtKey] ?? .null,
              let highlightedAt = SidecarISO8601.date(from: highlightedRaw)
        else { return nil }
        self.init(
            id: id,
            messageID: messageID,
            subject: Self.optionalString(object[Self.subjectKey]),
            senderName: Self.optionalString(object[Self.senderNameKey]),
            senderAddress: Self.optionalString(object[Self.senderKey]),
            sentAt: Self.optionalString(object[Self.sentAtKey]).flatMap(SidecarISO8601.date(from:)),
            highlightedAt: highlightedAt
        )
    }

    private static func optionalString(_ value: JSONValue?) -> String? {
        guard case .string(let string) = value ?? .null else { return nil }
        return string
    }
}
