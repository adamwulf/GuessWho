import CryptoKit
import Foundation

/// A durable, cross-device identity record for a favorited Contacts group.
///
/// A `CNGroup.identifier` is device-local — the same group carries a different
/// identifier on each device after iCloud/CardDAV sync, exactly like
/// `Contact.localID` (`docs/contact-identity.md`). So a group favorite cannot
/// reference the raw group identifier and expect it to resolve on another
/// device. Instead every favorited group gets a `GroupIdentity` with a minted,
/// cross-device-stable UUID; the favorite references THAT UUID, the same way
/// contact/event/guide/place favorites reference a UUID.
///
/// The record carries the group's normalized name, an optional account hint, a
/// best-effort `memberCount` and `memberHash` (a fingerprint over the members'
/// GuessWho IDs, which ARE cross-device stable), and a per-device
/// `[deviceID: localID]` map. Each device finds its matching local group by
/// name + membership fingerprint, then pins its own `localID` into the map and
/// resolves by that slot thereafter. See `plans/group-favorite-identity.md`.
public struct GroupIdentity: Codable, Sendable, Hashable {
    /// Minted once, cross-device stable. Canonical lowercase UUID string. This
    /// is the value the favorite references (like every other favorite kind).
    public let id: String

    /// Normalized group name (see `normalizedName(_:)`). Kept fresh on rename.
    /// The permanent fallback key for any device that has not adopted yet.
    public var name: String

    /// Best-effort account/container hint used ONLY to narrow duplicate-name
    /// matches (never a hard key). e.g. `"cardDAV:iCloud"`. Optional.
    public var account: String?

    /// Best-effort membership size. Includes members with no GuessWho ID yet,
    /// so it is supplied by the caller rather than derived from `memberHash`.
    public var memberCount: Int

    /// Best-effort fingerprint over the members' GuessWho IDs (see
    /// `fingerprint(forGuessWhoIDs:)`). Advisory only — a mismatch never
    /// rejects a sole name match, because un-reconciled members change the
    /// hash without changing the group.
    public var memberHash: String

    /// Number of members actually folded into `memberHash` (members that had a
    /// GuessWho ID at compute time). `memberCount - hashedMemberCount` is the
    /// count of un-reconciled members, which is why the hash is advisory.
    public var hashedMemberCount: Int

    /// Per-device pin. Each device writes ONLY its own slot, so a device can
    /// prune a dangling handle without touching another device's entry.
    /// `deviceID -> CNGroup.identifier`.
    public var deviceLocalIDs: [String: String]

    public init(
        id: String,
        name: String,
        account: String? = nil,
        memberCount: Int,
        memberHash: String,
        hashedMemberCount: Int,
        deviceLocalIDs: [String: String] = [:]
    ) {
        // Canonicalize the id to lowercase at construction, matching every
        // other UUID identity in the package (`SidecarKey.init`, GuessWho IDs).
        self.id = id.lowercased()
        self.name = name
        self.account = account
        self.memberCount = memberCount
        self.memberHash = memberHash
        self.hashedMemberCount = hashedMemberCount
        self.deviceLocalIDs = deviceLocalIDs
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case account
        case memberCount
        case memberHash
        case hashedMemberCount
        case deviceLocalIDs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Route the decoded id through the same lowercase canonicalization the
        // memberwise init applies, so a hand-written or peer-written record with
        // an upper-case id still resolves under the canonical key.
        let rawID = try container.decode(String.self, forKey: .id)
        let name = try container.decode(String.self, forKey: .name)
        // Scalar/collection fields default defensively so a partially-populated
        // peer record still decodes (treated as "advisory fields unknown")
        // rather than reading as an unavailable record.
        let account = try container.decodeIfPresent(String.self, forKey: .account)
        let memberCount = try container.decodeIfPresent(Int.self, forKey: .memberCount) ?? 0
        let memberHash = try container.decodeIfPresent(String.self, forKey: .memberHash) ?? ""
        let hashedMemberCount = try container.decodeIfPresent(Int.self, forKey: .hashedMemberCount) ?? 0
        let deviceLocalIDs = try container.decodeIfPresent([String: String].self, forKey: .deviceLocalIDs) ?? [:]
        self.init(
            id: rawID,
            name: name,
            account: account,
            memberCount: memberCount,
            memberHash: memberHash,
            hashedMemberCount: hashedMemberCount,
            deviceLocalIDs: deviceLocalIDs
        )
    }
}

extension GroupIdentity {
    /// Normalize a group name into the cross-device match key stored in
    /// `name`. Trims surrounding whitespace, applies Unicode canonical
    /// composition (so two devices that disagree on NFC vs. NFD for the same
    /// display name still produce the same key), and case-folds. The live
    /// group's user-visible name comes from its `CNGroup`, not from this key.
    public static func normalizedName(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
            .lowercased()
    }

    /// A membership fingerprint plus the number of members that fed it.
    public struct Fingerprint: Sendable, Hashable {
        /// SHA-256 hex over the lowercased, de-duplicated, sorted,
        /// newline-joined GuessWho IDs.
        public let memberHash: String
        /// Count of DISTINCT (folded) GuessWho IDs that fed the hash.
        public let hashedMemberCount: Int

        public init(memberHash: String, hashedMemberCount: Int) {
            self.memberHash = memberHash
            self.hashedMemberCount = hashedMemberCount
        }
    }

    /// Compute the membership fingerprint over a group's members' GuessWho IDs.
    ///
    /// Pass ONLY the IDs of members that already carry a GuessWho ID — a member
    /// with none is skipped here (and counted separately in `memberCount` by the
    /// caller, which is why the hash is advisory). The IDs are lowercased,
    /// de-duplicated (a unified contact counts once), sorted (order-independent),
    /// and newline-joined before SHA-256 — the house pattern for deterministic,
    /// cross-device-stable digests (`ContactDeterministicMint`, `Event.stableID`).
    /// `hashedMemberCount` is the number of distinct folded IDs.
    public static func fingerprint(forGuessWhoIDs ids: [String]) -> Fingerprint {
        let folded = Set(ids.map { $0.lowercased() }).sorted()
        let joined = folded.joined(separator: "\n")
        let digest = SHA256.hash(data: Data(joined.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return Fingerprint(memberHash: hex, hashedMemberCount: folded.count)
    }
}
