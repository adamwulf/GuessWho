import CryptoKit
import Foundation

// Deterministic GuessWho-ID minting (plans/cli-mcp.md Revision 2).
//
// The CLI/MCP wire sends a contact's GuessWho UUID as its id. A contact
// that has never been written to has no GuessWho URL yet — but agents must
// still be able to reference it (the flagship bulk-enrich population is
// exactly the never-reconciled contacts). Rather than minting randomly and
// letting the wire id change out from under an agent at first write, the
// mint itself is DETERMINISTIC: derived from the contact's device-local
// Contacts identifier plus its normalized display name. The wire can then
// send the same value BEFORE the mint (as a preview of what the contact
// will mint to) and AFTER it (as the real, durable GuessWho ID) — one id,
// stable across the mint boundary.
//
// Embedding the display name doubles as the stale-localID guard: if system
// unification silently re-points the localID at a DIFFERENT person, the
// derivation no longer matches, so a cached pre-mint id stops resolving
// instead of landing a write on the wrong card.
//
// Cross-device note (decided by Adam, 2026-07-17): localIDs are device-
// local, so two devices that independently first-write the same contact
// still mint DIFFERENT UUIDs — exactly as they did with random minting —
// and the existing Case-D lex-smallest reconciliation converges them. The
// deterministic mint does not attempt cross-device agreement.
extension Contact {
    /// The GuessWho UUID this contact WILL mint on its first GuessWho
    /// write — or, once minted through `handleCaseA`, HAS minted. Canonical
    /// lowercase UUID string, same format/validation as every GuessWho ID
    /// (`SidecarKey.parseGuessWhoContactURL` round-trips it).
    ///
    /// `package` on purpose: identity strings never reach the app layer
    /// (docs/contact-identity.md); the repository and the MCP dispatch core
    /// are the only consumers.
    package var deterministicGuessWhoID: String {
        Self.deterministicGuessWhoID(localID: localID, displayName: displayName)
    }

    /// SHA-256 over `localID` + "\n" + the trimmed, lowercased display
    /// name; first 16 bytes formatted as an RFC 4122 UUID (same recipe as
    /// `Event.stableID(forEventKitID:)`). Same inputs always yield the same
    /// UUID; a 128-bit digest makes collisions across a contact book
    /// negligible.
    package static func deterministicGuessWhoID(localID: String, displayName: String) -> String {
        let normalizedName = displayName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let digest = SHA256.hash(data: Data((localID + "\n" + normalizedName).utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        )).uuidString.lowercased()
    }
}
