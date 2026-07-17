import Foundation
import GuessWhoSync

/// What a sealed wire id refers to, host-side only. NEVER serialized —
/// several cases carry exactly the identifiers the wire must not leak
/// (restoration tokens, Apple local ids, raw record UUIDs; INV-3b).
public enum HandleReferent: Hashable, Sendable {
    case contact(ContactRestorationToken)
    case group(localID: String)
    /// `uuid` is the event's stable id string; `eventKitID` rides along so
    /// an un-adopted system event (no GuessWho record of its own yet) can
    /// still be re-fetched for events_get. Reads never mint records.
    case event(uuid: String, eventKitID: String?)
    case guide(UUID)
    case place(UUID)
    case note(UUID)
    case customField(UUID)
    case tag(UUID)
    case link(UUID)
}

/// The sealed capability-handle map (plans/cli-mcp.md wire identity).
///
/// Wire ids are opaque, per-HOST-RUN random tokens. The registry keeps the
/// only mapping back to real identity, in memory:
///
/// * Handles live for one host run and survive a helper re-handshake
///   within it. The map is NEVER persisted; after an app restart every old
///   handle resolves to nothing and callers surface the typed stale-id
///   error telling the agent to search again.
/// * Minting is idempotent per referent (same record → same handle within
///   a run) so ids are stable across repeated lists in one session.
/// * For contacts that carry no durable GuessWho identity yet, a display-
///   name fingerprint is snapshotted AT MINT. Phase 2's writes compare it
///   before writing (Apple can silently re-point such a contact's local id
///   at a different person via link/unlink in Contacts.app); Phase 1 only
///   records it.
/// * Handles are 128-bit CSPRNG hex — unguessable (no enumeration), and
///   deliberately NOT UUID-shaped so output scanners can assert "no bare
///   UUID crosses the wire".
public actor HandleRegistry {
    public struct Entry: Sendable {
        public let referent: HandleReferent
        /// Display-name fingerprint for contacts minted without a durable
        /// GuessWho identity; nil otherwise.
        public let fingerprint: UInt64?
    }

    private var byHandle: [String: Entry] = [:]
    private var byReferent: [HandleReferent: String] = [:]

    public init() {}

    /// Mint (or re-use) the sealed handle for a referent.
    public func handle(for referent: HandleReferent, fingerprint: UInt64? = nil) -> String {
        if let existing = byReferent[referent] { return existing }
        let handle = Self.mintToken()
        byHandle[handle] = Entry(referent: referent, fingerprint: fingerprint)
        byReferent[referent] = handle
        return handle
    }

    /// Resolve a wire id back to its referent. `nil` means the id was not
    /// minted in this host run (host restarted, or the agent invented it):
    /// callers answer with the typed stale-id error, never a transport-ish
    /// failure.
    public func entry(for handle: String) -> Entry? {
        byHandle[handle]
    }

    private static func mintToken() -> String {
        var generator = SystemRandomNumberGenerator()
        let hi = generator.next()
        let lo = generator.next()
        return String(format: "%016lx%016lx", hi, lo)
    }

    /// Stable (process-independent) FNV-1a hash of a contact's display
    /// name, for the nil-identity mint fingerprint.
    public static func displayNameFingerprint(_ contact: Contact) -> UInt64 {
        let normalized = contact.displayName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in normalized.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return hash
    }
}
