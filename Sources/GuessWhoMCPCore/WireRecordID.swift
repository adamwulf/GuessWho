import CryptoKit
import Foundation
import GuessWhoSync

/// The wire id scheme (plans/cli-mcp.md Revision 2) — plain, durable ids;
/// NO per-run map, NO sealed handles.
///
/// * **Contact** → its GuessWho UUID. For a contact that hasn't minted one
///   yet, the id is `Contact.deterministicGuessWhoID` — the exact UUID the
///   deterministic mint WILL assign on first write, so the id is stable
///   across the mint boundary. Resolution scans the live book: first for a
///   carried GuessWho UUID, then for a matching deterministic derivation
///   (which embeds the display name, so a localID that unification
///   re-pointed at a different person stops resolving instead of
///   misdirecting a write).
/// * **Event** → the record UUID when the event has a GuessWho record;
///   otherwise an id DERIVED from the system calendar identifier
///   (`e-` + base64url), reversible host-side only, so the write path can
///   still answer the Option-B "open it in the app first" error without a
///   session map.
/// * **Group** → a one-way digest of the group's Apple local identifier
///   (`g-` + 32 hex). Local identifiers themselves never cross the wire;
///   resolution re-derives over the fetched groups.
/// * Notes / custom fields / tags / links / guides / places → their own
///   record UUIDs, sent directly.
enum WireRecordID {
    // MARK: - Contacts

    /// The wire id for a contact: its GuessWho UUID, minted or previewed.
    static func contactID(for contact: Contact) -> String {
        contact.contactID.restorationToken.guessWhoID ?? contact.deterministicGuessWhoID
    }

    /// Find the contact a wire id refers to. `nil` = nothing matches (the
    /// record is gone, the id was invented, or — for a pre-mint id — the
    /// contact's identity inputs changed underneath it).
    static func contact(for id: String, in contacts: [Contact]) -> Contact? {
        let wanted = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard UUID(uuidString: wanted) != nil else { return nil }
        if let minted = contacts.first(where: {
            $0.contactID.restorationToken.guessWhoID == wanted
        }) {
            return minted
        }
        // Pre-mint preview id: re-derive. Matching contacts that HAVE a
        // (different) minted UUID are deliberately included — an id handed
        // out just before the mint keeps resolving as long as the localID
        // + name still derive to it.
        return contacts.first(where: { $0.deterministicGuessWhoID == wanted })
    }

    // MARK: - Events

    private static let eventPrefix = "e-"

    /// Whether this event row is a system-calendar-only row (no GuessWho
    /// record): its id is the derived placeholder for its calendar id.
    static func isSystemOnlyEvent(_ event: Event) -> Bool {
        guard let eventKitID = event.eventKitID else { return false }
        return event.id == Event.stableID(forEventKitID: eventKitID)
    }

    /// The wire id for an event: the record UUID, or the derived
    /// `e-`-prefixed form for a system-only row.
    static func eventID(for event: Event) -> String {
        if let eventKitID = event.eventKitID, isSystemOnlyEvent(event) {
            return eventPrefix + base64URL(eventKitID)
        }
        return event.id.uuidString.lowercased()
    }

    /// What an event wire id refers to, before hitting a data source.
    enum ParsedEventID {
        /// A record UUID string (lowercased).
        case record(String)
        /// A system calendar identifier recovered from an `e-` id.
        case system(eventKitID: String)
    }

    static func parseEventID(_ id: String) -> ParsedEventID? {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix(eventPrefix) {
            guard let decoded = decodeBase64URL(String(trimmed.dropFirst(eventPrefix.count))) else {
                return nil
            }
            return .system(eventKitID: decoded)
        }
        guard UUID(uuidString: trimmed) != nil else { return nil }
        return .record(trimmed.lowercased())
    }

    // MARK: - Groups

    private static let groupPrefix = "g-"

    /// The wire id for a contact group: a one-way digest of its Apple
    /// local identifier (the identifier itself is in the exclusion set).
    static func groupID(for group: ContactGroup) -> String {
        groupPrefix + digest(group.localID)
    }

    /// Find the group a wire id refers to, by re-derivation.
    static func group(for id: String, in groups: [ContactGroup]) -> ContactGroup? {
        groups.first { groupID(for: $0) == id }
    }

    // MARK: - Record UUIDs

    /// Parse a plain record-UUID id (notes, fields, tags, links, guides,
    /// places). `nil` for anything not UUID-shaped.
    static func recordUUID(_ id: String) -> UUID? {
        UUID(uuidString: id.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: - Encoding helpers

    private static func digest(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8)).prefix(16)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func base64URL(_ input: String) -> String {
        Data(input.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func decodeBase64URL(_ input: String) -> String? {
        var base64 = input
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }
        guard let data = Data(base64Encoded: base64) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
