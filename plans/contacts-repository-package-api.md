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

### Terminology: relationships versus links

These are separate features and must never share an API or be described as the
same kind of connection:

- **Contact relationships** are `CNContactRelation` values stored by Contacts.
  Their target is only a display-name string. GuessWho resolves them against the
  cached contacts as a best-effort UI convenience; zero or many contacts may
  match. A relationship is not an identity edge and is never written as a
  GuessWho ID.
- **Contact links** are package `Link` sidecar records. Their endpoints are
  `SidecarKey(kind: .contact, id: <GuessWho UUID>)` values, so they are durable
  hard links between specific GuessWho contacts. They remain valid across
  devices and are rewritten by identity reconciliation if a Case-D canonical-ID
  collapse retires an endpoint ID.

Identity reconciliation concerns the GuessWho URL stored on a Contact and any
sidecar **links** that use its ID. It does not resolve or alter name-only
Contacts relationships.

### Package-owned

The package owns all operations that query, index, load, mutate, or establish
the identity of a contact. This includes cache queries and relationship lookup
over Contacts records.

The public API must use typed GuessWho IDs and return contact values carrying a
GuessWho ID. `localID` remains an adapter-internal token only.

`ContactsRepository` must be constructed with both `ContactStoreProtocol` and
the owning `GuessWhoSync`. The adapter supplies Contacts I/O; `GuessWhoSync`
supplies reconciliation, sidecar merge/delete, and Case-D link rewriting.
`SyncService.makeContactsRepository()` must pass both dependencies. Do not move
reconciliation onto `ContactStoreProtocol`: it would incorrectly couple the
Contacts adapter to sidecar state.

### App-owned

The app owns presentation state and rendering decisions:

- current search text for each screen;
- sorting appropriate to the screen and locale;
- A-Z section construction;
- empty/loading presentation and selection UI.

The app renders package query results; it must not maintain a second contact
cache, create an ID index, or query the Contacts adapter/service directly.

### Display-name ambiguity

`lookupByDisplayName()` must **not** move as a `[String: Contact]` dictionary.
That implementation silently selects the last duplicate display name, which is
not a defensible identity rule. Replace it with a package query returning all
matches. The app chooses a target only through explicit UI when a query is
ambiguous.

`CNContactRelation` carries free-form names rather than durable target IDs.
Consequently, reverse relationships are a best-effort package query, not
durable GuessWho-ID links. Durable contact links remain `Link` sidecar records.

Name-derived reverse results are named `ContactRelationMatch`, not
`ContactReference`. Each result identifies the **referencing** contact by
GuessWho ID and carries its relation label plus the matched relation-name text.
The queried target is identified by the method argument, but the underlying
edge remains a name comparison; it is not persisted as a target-ID edge. A
single relation can therefore match multiple same-named targets.

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
public func searchContacts(query: String, type: ContactType?) -> [GuessWhoContact]
public func contact(id: GuessWhoContactID) -> GuessWhoContact?
public func contacts(named displayName: String) -> [GuessWhoContact]
public func contactsReferencing(id: GuessWhoContactID) -> [ContactRelationMatch]
```

`GuessWhoContactID.rawValue` is the canonical lowercase bare UUID string, not
the `guesswho://` URL. It is constructed only through the existing
`SidecarKey.parseGuessWhoContactURL` / `SidecarKey.forContact` path, so the
package has one UUID validator and canonicalizer. `GuessWhoContact.id` is
derived from that canonical post-reconciliation contact URL.

`ContactRelationMatch` contains the referencing contact's GuessWho ID, label,
and matched name text. It must not expose `localID`. The existing app navigation
type keeps the distinct name `ContactReference` until Stage 3 replaces it with
`ContactDestination` keyed by `GuessWhoContactID`.

For the migration, the repository may retain internal `GuessWhoContactID ↔
localID` indexes plus a session-local loser-to-canonical alias map. They are
rebuilt from the cached snapshot and updated atomically during incremental
mutations. `contact(id:)` resolves aliases, so an existing navigation/favorite
reference continues to load after a Case-D collapse. No app type may receive
any index or alias map.

## Implementation stages

### 1. Establish package identity/read-model types

1. Add `GuessWhoContactID`, built from `SidecarKey.forContact` rather than a
   parallel UUID parser, and add `GuessWhoContact` / `ContactRelationMatch`.
2. Change repository construction to receive `GuessWhoSync` as well as the
   adapter. Update `SyncService.makeContactsRepository()` accordingly.
3. Add an explicit `bootstrapIdentityBaseline()` operation. At launch/foreground
   it runs the full reconciliation sweep once, then fetches and publishes the
   identified snapshot. Do **not** silently make every `reload()` a write sweep:
   ordinary reload remains a read refresh after the baseline is established.
   The full sweep can perform one write per Case A/C/D contact and must show a
   loading/error state. On first-baseline failure publish an empty, explicitly
   unavailable snapshot; on a later failure retain the prior complete snapshot.
4. Maintain private ID-to-localID and localID-to-ID indexes with the cache.
   Rebuild after a full reload; update atomically with incremental mutations;
   retain loser-to-winner aliases for the process lifetime.
5. For every incremental `.updated(localID:)`, fetch, reconcile that record,
   re-fetch it, then replace its cache/index entry in one publication. On Case
   D, remove stale loser mappings, add old-to-canonical aliases, and emit one
   coherent snapshot so ID-keyed list rows are removed/inserted together. A
   `.deleted(localID:)` uses the cached localID-to-ID mapping to remove the
   record and its active mapping without losing existing aliases.

Acceptance: every `GuessWhoContact` emitted by the repository has exactly one
canonical GuessWho ID; duplicate/malformed URL cases follow the existing
reconciler rules; an old Case-D loser ID resolves to its current canonical
record for the session; and no partially reconciled cache state is published.

### 2. Add package query operations

1. Add `allContacts`, `contacts(of:)`, `searchContacts`, and `contact(id:)` over the package
   cache. These are synchronous cache reads on the repository's main-actor
   surface; no query is allowed to enumerate `CNContactStore`.
2. Add `contacts(named:) -> [GuessWhoContact]`, normalized exactly once in the
   package. Preserve every match.
3. Add `contactsReferencing(id:)`, returning `ContactRelationMatch` values for
   all name-text matches. Exclude self by GuessWho ID, not `localID`; allow one
   source relation to appear for every same-named target because the target is
   name-derived rather than a durable edge.
4. Add package tests for full reload, incremental update/delete, ID lookups,
   duplicate display names, self exclusion, baseline failure, per-update
   reconciliation, Case-D aliasing during an incremental update, canonical-ID
   selection, and no-store-I/O cache reads. Verify no-I/O queries with a test
   store that fails any fetch after the snapshot has been seeded.

Acceptance: no package query returns or accepts a local ID outside an adapter
or reconciliation bridge.

### 3. Migrate app navigation and list identities

1. Change list diffable-data-source item identifiers, selection callbacks, and
   `contactsByLocalID` maps to `GuessWhoContactID` / `contactsByID` equivalents.
   Cover both People and Organizations list controllers.
2. In `NavigationReferences.swift`, rename app navigation `ContactReference`
   to `ContactDestination` and key it by `GuessWhoContactID`. Update all
   `GuessWhoSceneDelegate` Catalyst replacement and iPhone push paths in the
   same change; a half-migrated destination type is not permitted.
3. Re-root `ContactDetailView` on `GuessWhoContactID`, including its load,
   edit, save, delete, reconcile-after-write, related-contact rows, and
   `InfoRowData.contactLink` / `.backReference` payloads. ID-to-localID
   resolution happens only inside repository methods.
4. Change connections, event attendees, and favorites to receive/load contacts
   by GuessWho ID through the repository. Remove favorites' `uuidToContact` and
   all other app-built GuessWho-ID maps, including the detail view's
   `refreshContactMap`; use `repository.contact(id:)` instead.
5. For Contacts name-only relationships: render no target as non-actionable;
   navigate directly for one match; present an explicit disambiguation UI for
   multiple matches. Never silently select a duplicate display name.
6. `contact(id:)` resolves session aliases after a Case-D collapse. If it still
   returns nil (deleted contact, unavailable first baseline, or failed refresh),
   detail/navigation surfaces a non-crashing unavailable state and retains no
   stale localID fallback.
7. Keep any temporary adapter-local operation private inside repository methods
   such as `save(id:edit:)`, `delete(id:)`, and image fetches.

Acceptance: the app has no contact cache or GuessWho-ID index; grep confirms no
app code passes `localID` to navigation, stores it in a dictionary/set, or
persists it. The only allowed remaining occurrences are explicitly enumerated
adapter bridges and the debug-only Contact Detail display, each marked with a
`localID exception:` comment explaining why it cannot cross an app boundary.

### 4. Move contact operations from `SyncService`

1. Move contact fetch-for-editing, save, delete, reconcile-after-write, image
   fetch, and group operations into `ContactsRepository` or a package-owned
   contact service used exclusively by it.
2. `SyncService` remains app composition: permissions, sidecar root/device
   configuration, event functionality, and construction of package services.
3. Update views to use the repository for all contact work. They may still use
   `SyncService` for events and app-level authorization state.
4. Preserve `CNContactStore` transaction-author tagging and change-history
   exclusion for repository-owned writes. Own writes update the cache directly;
   they must not reappear as external watcher deltas.

Acceptance: contact screens have no direct `SyncService` dependency except a
permission-state binding if that remains necessary for UI.

### 5. Delete the extension and tighten visibility

1. Move no presentation code into the package; replace app extension usages
   with local view/controller presentation helpers operating on
   `[GuessWhoContact]`.
2. Delete `App/GuessWho/Support/ContactsRepository.swift`.
3. Make `Contact.localID` non-public or otherwise unavailable to app clients
   once all migration call sites are gone.
4. Remove obsolete `SyncService` contact wrappers. Keep/add tests for the new
   package API; no existing repository tests need to be removed.

Acceptance: there is one `ContactsRepository`, located in
`Sources/GuessWhoSync`; it is the sole production contact API used by the app.

## Verification and review cycle

Each stage is a gate: focused package tests and a Catalyst app build must be
green before proceeding to the next stage. At the end:

1. Run `swift test`. If the harness blocks SwiftPM's sandbox, rerun
   `swift test --disable-sandbox` and record that harness-specific reason.
2. Run `xcodebuild -project App/GuessWho.xcodeproj -scheme GuessWho -destination
   'platform=macOS,variant=Mac Catalyst' -derivedDataPath <local path> build`.
3. Run a static identity audit using `grep` for app `localID` use and classify
   every remaining occurrence as an explicitly documented adapter bridge,
   debug-only, or a migration defect. Also audit for app-side `[GuessWhoContact]`
   caches and `GuessWhoContactID` dictionaries/sets; those are migration defects
   except short-lived view-local rendering input.
4. Perform a review cycle covering identity correctness, cache coherence,
   relationship ambiguity, Swift concurrency/actor isolation, and UI regression
   risk. Resolve all findings before declaring the extension removal complete.
