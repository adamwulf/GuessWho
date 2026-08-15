# Plan: durable cross-device identity for group favorites

## Status (2026-08-14)

Approved, ready to build. This plan replaces the current group-favorite key
(`CNGroup.identifier`, a device-local value) with a durable, cross-device
group-identity record. It follows the strategy Adam chose:

- a **`[deviceID: localID]` map** per group, so each device pins its own
  Contacts handle and can prune only its own slot;
- a **`memberCount`** and a **`memberHash`** (a fingerprint over the members'
  GuessWho IDs), used to tell apart two groups that share a name;
- best-effort updates on membership change and on app start.

### Decisions locked (2026-08-14)

- **Hash:** CryptoKit **SHA-256** (the house pattern; zero new dependency).
  `xxHash-Swift` is NOT added.
- **Storage:** a **per-group sidecar** keyed by a minted group UUID. The
  favorite references that UUID.
- **Duplicate name + identical membership:** do NOT try to tell them apart.
  On more than one same-name candidate, pick deterministically and log. The
  hash still earns its keep for same-name / *different*-membership groups.
- **Migration:** NONE. Single user; legacy data is rebuilt by hand. Old
  `.group` favorites (raw `CNGroup.identifier` ids) simply resolve to
  "unavailable" and can be un-favorited. No migration code, no
  `schemaVersion` gate.

## The problem this fixes

A `CNGroup.identifier` is **device-local**. The same group has a different
identifier on each device after iCloud/CardDAV sync — the same property that
makes `Contact.localID` unusable as identity (`docs/contact-identity.md:226`).

Today a group favorite stores that device-local identifier directly:

- `Favorite.id` = `CNGroup.identifier`, lowercased (`Sources/GuessWhoSync/Favorite.swift:6`).
- Write path: `ContactsRepository.setGroupFavorite(_:for:)` →
  `favorites.toggle(kind: .group, id: group.localID, …)`
  (`Sources/GuessWhoSync/ContactsRepository.swift:1721`).
- `Favorites.json` syncs across devices (`Sources/GuessWhoSync/FavoritesStore.swift:1`).
- Read path: `group(localID:)` looks the id up in the device's group cache
  (`Sources/GuessWhoSync/ContactsRepository.swift:1735`, `1781`).

So a group favorited on the phone stores the phone's identifier. The file
syncs to the Mac. The Mac has the same group with a **different** identifier,
finds no match, and shows the row as unavailable. That is the reported bug.

A `CNGroup` has **no writable field** to carry a token (a `CNMutableGroup`
exposes only `name`), so — unlike a contact — we cannot plant a
`guesswho://` URL on the group. Any cross-device group identity must come from
the group's own synced attributes: its **name**, and a **fingerprint of its
membership** (GuessWho IDs are cross-device stable, so a hash over them is
stable too).

## Strategy in one paragraph

Give each favorited group a small **group-identity record** with a minted,
cross-device GuessWho **group UUID**. The favorite references that UUID, the
same way contact/event/guide/place favorites already reference a UUID. The
record carries the group's normalized name, an optional account hint, a
`memberCount`, a `memberHash`, and a `[deviceID: localID]` map. Each device
finds its matching local group by **name + membership fingerprint**, then
writes its own `localID` into the map. From then on that device resolves by
its own `localID`, which is stable across renames on that device. The name,
count, and hash are refreshed best-effort so a not-yet-adopted device can
still match later.

## Data model

### `GroupIdentity` (new; lives in the sync package)

```swift
public struct GroupIdentity: Codable, Sendable, Hashable {
    /// Minted once, cross-device stable. This is the value the favorite
    /// references (like every other favorite kind).
    public let id: String                 // lowercased UUID string

    /// Normalized group name. Kept fresh on rename. The permanent fallback
    /// key for any device that has not adopted yet.
    public var name: String

    /// Best-effort account/container hint used ONLY to narrow duplicate-name
    /// matches (never a hard key). e.g. "cardDAV:iCloud". Optional.
    public var account: String?

    /// Best-effort membership size. Includes members with no GuessWho ID yet.
    public var memberCount: Int

    /// Best-effort fingerprint over the members' GuessWho IDs (see Hashing).
    /// Advisory only — a mismatch never rejects a sole name match, because
    /// un-reconciled members change the hash without changing the group.
    public var memberHash: String

    /// Number of members actually folded into `memberHash` (members that had a
    /// GuessWho ID at compute time). `memberCount - hashedMemberCount` is the
    /// count of un-reconciled members, which is why the hash is advisory.
    public var hashedMemberCount: Int

    /// Per-device pin. Each device writes ONLY its own slot, so a device can
    /// prune a dangling handle without touching another device's entry.
    public var deviceLocalIDs: [String: String]   // deviceID -> CNGroup.identifier
}
```

### `Favorite` change

- A `.group` favorite's `id` becomes the **group UUID** (`GroupIdentity.id`),
  not the `CNGroup.identifier`. That makes `.group` consistent with every
  other kind and keeps `Favorites.json` small and churn-free.
- `Favorite.matches`, `stableID`, and the codable shape are unchanged — only
  the meaning of `id` for `.group` changes.

### Where `GroupIdentity` is stored — chosen: per-group sidecar

**A per-group sidecar**, keyed by the minted group UUID, written through the
existing sidecar store (which already has per-key conflict reconciliation via
`reconcileSidecars()`), NOT inline in `Favorites.json`.

Reasons:

- **Write isolation.** `memberCount`/`memberHash` update whenever membership
  changes. `Favorites.json` is a single file with whole-file last-writer-wins
  (`FavoritesStore.swift:8-13`). Putting membership churn there would fight
  every reorder/toggle. A per-group sidecar isolates that write to one file.
- **Map convergence.** The `deviceLocalIDs` map wants a **union merge** on
  conflict (each device authors only its own key, so union is safe and never
  loses a slot). The sidecar reconcile path is the place to implement a
  field-level merge; the favorites file has none.
- **Layering.** The whole app keeps raw `localID` out of app/feature code and
  confines it to the package reconcile boundary
  (`docs/contact-identity.md:361-364`). A package-owned group sidecar + a
  reconcile step preserves that discipline. Storing the map inline in the
  favorites projection would leak `localID` handling into it.
- **Future.** If group notes/tags ever appear, they hang off the same UUID.

Records are minted **lazily** — only a favorited group gets one — so we never
write identity records for the hundreds of groups a user does not care about.

(An inline-on-`Favorite` alternative was considered and rejected: it inherits
`Favorites.json` whole-file LWW and sprinkles `localID` into the favorites
layer.)

### `deviceID`

- A **device-local, persisted UUID**, minted once and reused. It is the *key*
  of `deviceLocalIDs`; it is never itself synced as content.
- Store it beside the existing device-local change-history cursor
  (`ContactSyncCursorStore`) — same "device-local, safe to lose, regenerate on
  loss" contract. Do **not** use `identifierForVendor` (UIKit-only; the
  package is UIKit-free; it also resets when the vendor's apps are all
  removed).

## Hashing — chosen: CryptoKit SHA-256

Reuse CryptoKit SHA-256, which the repo already uses for exactly this purpose
(deterministic, cross-device-stable IDs):

- `ContactDeterministicMint.deterministicGuessWhoID` — SHA-256 over
  `localID + "\n" + normalizedName` (`Sources/GuessWhoSync/ContactDeterministicMint.swift:49`).
- `Event` deterministic id — SHA-256 over the EventKit id (`Sources/GuessWhoSync/Event.swift:116`).

SHA-256 is deterministic across OS, arch, and version by spec — the only
property a cross-device fingerprint needs. The member set is tiny (tens of
UUIDs), so hash speed is irrelevant. Reusing it means **zero new
dependencies** and matches the house pattern.

`memberHash` = SHA-256 (hex, or first 16 bytes hex) over the members' GuessWho
IDs, **lowercased, de-duplicated, sorted, and newline-joined** (sort →
order-independent; dedup → a unified contact counts once). Only members that
already have a GuessWho ID are included; `hashedMemberCount` records how many
that was.

(`xxHash-Swift` was considered and declined — it would add a third-party
dependency for a capability the repo already has. No `Package.swift` /
`Package.resolved` changes are needed for this feature.)

## Adoption / reconcile algorithm

The one place a `localID` is an input, mirroring the contact reconcile
boundary. All of it lives in the package/repository.

**Resolve a `.group` favorite (UUID `G`) to a local `ContactGroup`:**

1. Load `GroupIdentity` for `G`. If missing, the favorite is unresolved →
   render the existing "unavailable" row (`FavoriteListItem.swift:15-18`).
2. **Fast path — my slot.** `let mine = record.deviceLocalIDs[deviceID]`.
   If `mine` resolves to a live group on this device (`group(localID: mine)`),
   return it. This is rename-proof on this device.
3. **Prune my dead slot.** If `mine` is set but no longer resolves (re-mint,
   group deleted), remove `record.deviceLocalIDs[deviceID]` and continue.
4. **Match by name (+ account hint).** Collect this device's groups whose
   normalized name equals `record.name` (narrow by `account` when both sides
   have one).
   - 0 candidates → unresolved on this device (unavailable row). Do not guess.
   - 1 candidate → adopt it (go to step 6). Count/hash are irrelevant here, so
     an un-reconciled-member hash mismatch never causes a false orphan.
   - >1 candidates → **disambiguate** (step 5).
5. **Disambiguate same-name candidates.** Score each candidate by comparing
   its freshly computed `(memberCount, memberHash)` to the record's:
   hash-equal beats count-equal beats neither. Pick the best. On a tie (which
   includes the "identical name + identical membership" case we chose not to
   solve), pick deterministically — lowest local identifier — and log a
   breadcrumb; never crash, never pick two.
6. **Pin + refresh (best-effort write).** Set
   `record.deviceLocalIDs[deviceID] = candidate.identifier`; refresh
   `record.name`, `account`, `memberCount`, `memberHash`, `hashedMemberCount`
   from the live group; persist via the sidecar store. Return the candidate.

**Merge policy (sidecar reconcile):** on a conflict between two versions of a
`GroupIdentity` file, **union** the `deviceLocalIDs` maps (per-key, each key
authored by one device) and take the most-recent scalar fields
(`name`/`account`/`memberCount`/`memberHash`). If a custom field-merge is not
worth wiring initially, fall back to whole-file LWW: a slot lost to LWW
self-heals on that device's next resolve (step 6 re-pins it). Ship LWW first;
add the union merge if slot churn proves noticeable.

## Membership fingerprint updates (best-effort)

Recompute `memberCount` / `memberHash` for a group **that has an identity
record** on:

- `.contactsRepositoryGroupMembershipDidChange`
  (`Sources/GuessWhoSync/ContactsRepository.swift:48`, keys at `:683`) — the
  `groupLocalID` tells us which record to refresh;
- `loadGroups()` / app start (`Sources/GuessWhoSync/ContactsRepository.swift:399`);
- lazily, on the resolve path (step 6 already refreshes the matched group).

Compute cost is bounded: `fetchMemberLocalIDs(ofGroup:)`
(`Sources/GuessWhoSync/CNContactStoreAdapter.swift:513`) → map each member
`localID` to its GuessWho ID via the contact cache (a member with no GuessWho
ID is skipped in the hash but counted in `memberCount`) → SHA-256. No forced
minting: we never reconcile a contact just to fingerprint a group.

## No migration of existing group favorites

By decision: single user, rebuild by hand. We write no migration code. Old
`.group` favorites store `id = CNGroup.identifier`; after this change no
`GroupIdentity` record has that id, so those rows resolve to "unavailable"
(`FavoriteListItem.swift:15-18`) and the user un-favorites them and
re-favorites the group. No `schemaVersion` gate, no rewrite pass.

## Known limitations (state them; do not pretend they vanish)

- **Duplicate names + identical membership** still can't be told apart. Two
  groups with the same name AND the same members hash the same. Rare;
  disambiguation picks deterministically and logs.
- **Un-reconciled members make the hash advisory.** Two devices with different
  subsets of members reconciled produce different hashes for the same group.
  That is why the hash only *disambiguates* multiple name matches and never
  *rejects* a sole name match.
- **Local ("On My Mac") groups** have no cross-device counterpart; no scheme
  resolves them across devices.
- **Rename-before-adopt window.** If a group is renamed before another device
  ever adopts, that device matches only after `record.name` refresh has synced
  AND the CardDAV rename has synced — two independent channels, no ordering
  guarantee. A brief unavailable window can occur.
- **Whole-file LWW convergence** (if we ship LWW before the union merge): a map
  slot lost to a concurrent write self-heals on next resolve.

## Phases

1. **Package model + storage.** `GroupIdentity`, its sidecar read/write,
   `deviceID` store, SHA-256 `memberHash` helper. Unit tests for hash
   stability (sort/dedup/order-independence) and map union.
2. **Reconcile + resolve.** Adoption algorithm, prune, disambiguation,
   best-effort refresh. Repository API: `setGroupFavorite`/`isGroupFavorite`/
   `favoriteListItems` switch to the group UUID and route through resolve.
   Tests for each resolve outcome.
3. **Fingerprint updates.** Wire membership-change + `loadGroups` refresh.
4. **Review cycle.** Per repo policy (`docs`/memory: always run a review
   cycle). Build both destinations + `swift test`.

## Verification

- `swift build` / `swift test` from repo root (package). No `Package.resolved`
  changes — no new dependency.
- App builds: Catalyst + iPhone sim (`CLAUDE.md` → Building & testing).
- Manual: favorite a group on device A; confirm it resolves on device B;
  rename on A and confirm A still follows it; add/remove a member and confirm
  the fingerprint updates.

## Remaining minor decisions (default in-plan; not blockers)

1. **Account scoping:** include the `account` hint now, or defer until
   duplicate-name cases actually appear. Default: include a cheap hint; it is
   optional in the model.
2. **Merge:** ship whole-file LWW + self-heal re-pin first, add the
   `deviceLocalIDs` union merge later. Default: LWW first.
