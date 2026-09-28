import CryptoKit
import Foundation

/// One email message recorded against a contact — the "recent mail" activity
/// the Mail action handler reports and the contact card lists.
///
/// Stored as ONE additive cell on the contact's sidecar envelope, keyed
/// `mailActivity:<id>` (see `cellKey`). `GuessWhoSync.fields(at:)` skips
/// that key prefix explicitly, so the field-instance reads built on it (notes,
/// custom fields, the CLI/MCP field tools) never see these cells. An older
/// build that has never heard of them carries them through its raw-cell
/// read-modify-write untouched (docs/sidecar-compatibility.md).
///
/// `id` is DETERMINISTIC: derived from the normalized RFC 5322 Message-ID, so
/// a message the handler delivers twice lands on the same cell (idempotent),
/// and the same message recorded on two contacts that later collapse under
/// Case-D reconciliation merges into one cell instead of duplicating.
///
/// The synced format, retention, and merge rules: docs/mail-activity.md.
public struct MailActivity: Hashable, Sendable, Identifiable {
    /// Which way the message travelled relative to the user. Only incoming
    /// mail is recorded today; the raw value is the stored spelling.
    public enum Direction: String, Hashable, Sendable {
        case incoming
    }

    /// Stable identity derived from `messageID` (see `activityID(forMessageID:)`).
    public let id: UUID
    public let direction: Direction
    /// The sender's email address, trimmed of surrounding whitespace.
    public let senderAddress: String
    public let subject: String?
    /// When the message was received, at the sidecar's stored precision
    /// (milliseconds), so a value read back compares equal to the one written.
    public let receivedAt: Date
    /// The message's RFC 5322 Message-ID in normalized form: no angle
    /// brackets, no whitespace, domain part lowercased.
    public let messageID: String
    /// Optional deep link that reopens the message in Mail.
    public let mailURL: String?

    /// Builds an activity for the message identified by `messageID`. Returns
    /// nil when `messageID` is empty after normalization, because the
    /// activity would have no stable identity to deduplicate on.
    public init?(
        direction: Direction = .incoming,
        senderAddress: String,
        subject: String?,
        receivedAt: Date,
        messageID: String,
        mailURL: String? = nil
    ) {
        guard let normalized = Self.normalizedMessageID(messageID) else { return nil }
        self.init(
            id: Self.activityID(forNormalizedMessageID: normalized),
            direction: direction,
            senderAddress: senderAddress.trimmingCharacters(in: .whitespacesAndNewlines),
            subject: subject,
            receivedAt: Self.storedPrecision(receivedAt),
            messageID: normalized,
            mailURL: mailURL
        )
    }

    /// Memberwise init for decode; takes already-normalized values.
    init(
        id: UUID,
        direction: Direction,
        senderAddress: String,
        subject: String?,
        receivedAt: Date,
        messageID: String,
        mailURL: String?
    ) {
        self.id = id
        self.direction = direction
        self.senderAddress = senderAddress
        self.subject = subject
        self.receivedAt = receivedAt
        self.messageID = messageID
        self.mailURL = mailURL
    }

    /// The deterministic activity id for `messageID`, or nil when it is empty
    /// after normalization. Any spelling of the same Message-ID (with or
    /// without angle brackets, folded whitespace, domain case) yields the
    /// same id.
    public static func activityID(forMessageID messageID: String) -> UUID? {
        normalizedMessageID(messageID).map(activityID(forNormalizedMessageID:))
    }

    /// Normalizes an RFC 5322 Message-ID for identity: drops all whitespace
    /// (header folding), strips one enclosing `<` `>` pair, and lowercases the
    /// part after the last `@` (domains are case-insensitive; the local part
    /// is not, so it keeps its case). Returns nil when nothing remains.
    static func normalizedMessageID(_ raw: String) -> String? {
        var value = raw.filter { !$0.isWhitespace }
        if value.count >= 2, value.hasPrefix("<"), value.hasSuffix(">") {
            value = String(value.dropFirst().dropLast())
        }
        guard !value.isEmpty else { return nil }
        if let at = value.lastIndex(of: "@") {
            value = String(value[..<at]) + value[at...].lowercased()
        }
        return value
    }

    /// SHA-256 over a namespaced Message-ID; first 16 bytes formatted as an
    /// RFC 4122 UUID (same recipe as `Event.stableID(forEventKitID:)`). The
    /// namespace keeps a Message-ID from ever hashing to the same UUID as an
    /// EventKit id with the same spelling.
    private static func activityID(forNormalizedMessageID messageID: String) -> UUID {
        let digest = SHA256.hash(data: Data(("mail-activity\n" + messageID).utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    /// Rounds `date` through the sidecar's ISO8601 spelling so the in-memory
    /// value equals what a later read decodes.
    private static func storedPrecision(_ date: Date) -> Date {
        SidecarISO8601.date(from: SidecarISO8601.string(from: date)) ?? date
    }
}

// MARK: - Cell encoding

extension MailActivity {
    // Stable on-disk spellings — part of the synced format, never change them.
    static let cellKeyPrefix = "mailActivity:"
    static let directionKey = "direction"
    static let senderKey = "sender"
    static let subjectKey = "subject"
    static let receivedAtKey = "receivedAt"
    static let messageIDKey = "messageID"
    static let mailURLKey = "mailURL"

    /// The fixed cell key this activity occupies on the contact envelope.
    var cellKey: String { Self.cellKeyPrefix + id.uuidString.lowercased() }

    /// Whether `cellKey` names a mail activity cell. Generic cell readers use
    /// this to keep these cells out of their projections.
    static func isCellKey(_ cellKey: String) -> Bool {
        cellKey.hasPrefix(cellKeyPrefix)
    }

    /// The cell's opaque value object for a first delivery. Optional members
    /// are omitted when nil.
    var cellValue: JSONValue { cellValue(overlaying: [:]) }

    /// The cell value for a repeat delivery onto an existing live value
    /// object: this build's keys are written over `existing`, every other key
    /// (one a newer build added) is kept, and an existing `subject` /
    /// `mailURL` is kept when this delivery has none.
    func cellValue(overlaying existing: [String: JSONValue]) -> JSONValue {
        var object = existing
        object[Self.directionKey] = .string(direction.rawValue)
        object[Self.senderKey] = .string(senderAddress)
        object[Self.receivedAtKey] = .string(SidecarISO8601.string(from: receivedAt))
        object[Self.messageIDKey] = .string(messageID)
        if let subject { object[Self.subjectKey] = .string(subject) }
        if let mailURL { object[Self.mailURLKey] = .string(mailURL) }
        return .object(object)
    }

    /// How many decodable live activities one contact keeps. The write that
    /// would exceed it removes the oldest (by `isNewer(than:)` order).
    ///
    /// Part of the synced format, like the cell keys. Each build prunes its
    /// own copy to its own limit on the next mail-activity write for a
    /// contact, and the sidecar merge is a union, so with mixed limits the set
    /// churns: a lower-limit build re-trims it while a higher-limit peer can
    /// re-add cells during a merge. A pruned cell is lost only once every
    /// device holding it has pruned it. Raising the limit is durable only once
    /// no lower-limit build still writes; lowering it makes each build discard
    /// the excess on its next write. Change it only as a deliberate format
    /// decision; see docs/mail-activity.md.
    static let retentionLimit = 100

    /// The one activity order: newer `receivedAt` first, ties broken by the
    /// `id` string so every device ranks the same set identically.
    func isNewer(than other: MailActivity) -> Bool {
        if receivedAt != other.receivedAt { return receivedAt > other.receivedAt }
        return id.uuidString < other.id.uuidString
    }

    /// Decodes one envelope cell, or nil when `cellKey` is not a mail
    /// activity key or the value is malformed or uses a direction this build
    /// does not know. Nil only hides the activity from reads; the cell stays
    /// in the envelope. Soft-deleted cells decode like live ones; callers filter.
    init?(cellKey: String, cell: SidecarCell) {
        guard Self.isCellKey(cellKey),
              let id = UUID(uuidString: String(cellKey.dropFirst(Self.cellKeyPrefix.count))),
              case .object(let object) = cell.value,
              case .string(let directionRaw) = object[Self.directionKey] ?? .null,
              let direction = Direction(rawValue: directionRaw),
              case .string(let sender) = object[Self.senderKey] ?? .null,
              case .string(let receivedRaw) = object[Self.receivedAtKey] ?? .null,
              let receivedAt = SidecarISO8601.date(from: receivedRaw),
              case .string(let messageID) = object[Self.messageIDKey] ?? .null
        else { return nil }
        self.init(
            id: id,
            direction: direction,
            senderAddress: sender,
            subject: Self.optionalString(object[Self.subjectKey]),
            receivedAt: receivedAt,
            messageID: messageID,
            mailURL: Self.optionalString(object[Self.mailURLKey])
        )
    }

    private static func optionalString(_ value: JSONValue?) -> String? {
        guard case .string(let string) = value ?? .null else { return nil }
        return string
    }
}
