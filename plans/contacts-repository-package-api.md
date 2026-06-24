# Plan: remove the app contact-repository extension

## Objective

Delete `App/GuessWho/Support/ContactsRepository.swift` entirely. The app must
consume the package-owned `ContactsRepository` for contact read/query/cache
operations, while retaining only presentation state and rendering policy.

The end state also enforces the identity boundary described in
[`docs/contact-identity.md`](../docs/contact-identity.md): application callers
identify contacts by GuessWho ID, never `Contact.localID`.

## Current state

`Sources/GuessWhoSync/ContactsRepository.swift` owns the in-memory contact
cache, full reload, incremental cache mutation, and the contact-change
subscription. The app file with the same name is an extension that still owns:

- people/organization filtering;
- per-tab search strings;
- display-name lookup used by relationship UI;
- reverse relationship lookup;
- sorting and A-Z section creation.

This split is transitional. It also leaves app code with `localID`-keyed
navigation and cache lookups, contrary to the identity contract.

## Boundary decisions

### Package-owned

The package owns all operations that query, index, load, mutate, or establish
the identity of a contact. This includes cache queries and relationship lookup
over Contacts records.

The public API must use typed GuessWho IDs and return contact values carrying a
GuessWho ID. `localID` remains an adapter-internal token only.

### App-owned

The app owns presentation state and rendering decisions:

- current search text for each screen;
- sorting appropriate to the screen and locale;
- A-Z section construction;
- empty/loading presentation and selection UI.

The app may filter an already-returned package snapshot for presentation, but
it must not maintain a second contact cache, create an ID index, or query the
Contacts adapter/service directly.

### Display-name ambiguity

`lookupByDisplayName()` must **not** move as a `[String: Contact]` dictionary.
That implementation silently selects the last duplicate display name, which is
not a defensible identity rule. Replace it with a package query returning all
matches. The app chooses a target only through explicit UI when a query is
ambiguous.

`CNContactRelation` carries free-form names rather than durable target IDs.
Consequently, reverse relations are a best-effort package query, not durable
GuessWho-ID links. Durable app-created links remain `Link` sidecar records.

## Target public model and API

Introduce an opaque, validated identity type:

```swift
public struct GuessWhoContactID: Hashable, Sendable, Codable {
    public let rawValue: String
}

public struct GuessWhoContact: Hashable, Sendable {
    public let id: GuessWhoContactID
    public let contact: Contact
}
```

`Contact.localID` should eventually become internal to the package. Do not make
that visibility-breaking change in the same commit as the repository API; first
migrate all app callers to `GuessWhoContact`.

The repository API should be shaped as follows (exact names may be adjusted to
fit Swift conventions):

```swift
public func allContacts() -> [GuessWhoContact]
public func contacts(of type: ContactType) -> [GuessWhoContact]
public func contact(id: GuessWhoContactID) -> GuessWhoContact?
public func contacts(named displayName: String) -> [GuessWhoContact]
public func contactsReferencing(id: GuessWhoContactID) -> [ContactReference]
```

`ContactReference` needs a package-owned value type containing the referencing
contact's GuessWho ID and the relation label. It must not expose `localID`.

For the migration, the repository may retain internal `GuessWhoContactID ↔
localID` indexes. They are rebuilt from the cached snapshot and updated during
incremental mutations. No app type may receive either index.

## Implementation stages

### 1. Establish package identity/read-model types

1. Add `GuessWhoContactID`, validating/canonicalizing UUID input.
2. Add `GuessWhoContact` and package `ContactReference` (choose a name that
   does not collide with the app navigation type; rename the app type during
   the migration if necessary).
3. Update repository reload to reconcile identities before publishing the first
   snapshot. Re-fetch the changed contacts after reconciliation so records carry
   their canonical ID.
4. Maintain private ID-to-localID and localID-to-ID indexes with the cache.
   Rebuild after a full reload; update atomically with incremental mutations.
5. Define behavior for a reconciliation failure: publish no partially identified
   record, retain a surfaced error, and leave the previous complete cache intact.

Acceptance: every `GuessWhoContact` emitted by the repository has exactly one
canonical GuessWho ID; duplicate/malformed URL cases follow the existing
reconciler rules.

### 2. Add package query operations

1. Add `allContacts`, `contacts(of:)`, and `contact(id:)` over the package
   cache. These are synchronous cache reads on the repository's main-actor
   surface; no query is allowed to enumerate `CNContactStore`.
2. Add `contacts(named:) -> [GuessWhoContact]`, normalized exactly once in the
   package. Preserve every match.
3. Add `contactsReferencing(id:)`, returning all name-text matches and labels.
   Exclude self by GuessWho ID, not `localID`.
4. Add package tests for full reload, incremental update/delete, ID lookups,
   duplicate display names, self exclusion, and no-store-I/O cache reads.

Acceptance: no package query returns or accepts a local ID outside an adapter
or reconciliation bridge.

### 3. Migrate app navigation and list identities

1. Change list diffable-data-source item identifiers, selection callbacks, and
   contact maps to `GuessWhoContactID`.
2. Replace `ContactReference(localID:)` with a GuessWho-ID reference.
3. Change `ContactDetailView`, connections, event attendees, and favorites to
   receive/load contacts by GuessWho ID through the repository.
4. Keep any temporary adapter-local operation private inside repository methods
   such as `save(id:edit:)`, `delete(id:)`, and image fetches.

Acceptance: grep confirms no app code passes `localID` to navigation, stores it
in a dictionary/set, or persists it. Debug-only display may expose it only if
explicitly justified and does not feed behavior.

### 4. Move contact operations from `SyncService`

1. Move contact fetch-for-editing, save, delete, reconcile-after-write, image
   fetch, and group operations into `ContactsRepository` or a package-owned
   contact service used exclusively by it.
2. `SyncService` remains app composition: permissions, sidecar root/device
   configuration, event functionality, and construction of package services.
3. Update views to use the repository for all contact work. They may still use
   `SyncService` for events and app-level authorization state.

Acceptance: contact screens have no direct `SyncService` dependency except a
permission-state binding if that remains necessary for UI.

### 5. Delete the extension and tighten visibility

1. Move no presentation code into the package; replace app extension usages
   with local view/controller presentation helpers operating on
   `[GuessWhoContact]`.
2. Delete `App/GuessWho/Support/ContactsRepository.swift`.
3. Make `Contact.localID` non-public or otherwise unavailable to app clients
   once all migration call sites are gone.
4. Remove obsolete `SyncService` contact wrappers and tests that assert the old
   app-facing local-ID API.

Acceptance: there is one `ContactsRepository`, located in
`Sources/GuessWhoSync`; it is the sole production contact API used by the app.

## Verification and review cycle

Each stage requires focused package tests plus a Catalyst app build. At the end:

1. Run `swift test --disable-sandbox`.
2. Run `xcodebuild -project App/GuessWho.xcodeproj -scheme GuessWho -destination
   'platform=macOS,variant=Mac Catalyst' -derivedDataPath <local path> build`.
3. Run a static identity audit using `grep` for app `localID` use and classify
   every remaining occurrence as adapter-internal, debug-only, or a migration
   defect.
4. Perform a review cycle covering identity correctness, cache coherence,
   relationship ambiguity, Swift concurrency/actor isolation, and UI regression
   risk. Resolve all findings before declaring the extension removal complete.
