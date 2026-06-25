# Contact Identity: `ContactID`, GuessWho ID, and localID

This document is the source of truth for how GuessWhoSync identifies a contact.
Read it before writing any code that fetches, stores, links, or compares
contacts.

## The one rule (three layers)

After the package-vended-`ContactID` migration there are **three** identity
layers, and which identifier is legal depends on which layer you are in:

1. **App layer → `ContactID`.** The app holds, compares, and fetches with an
   **opaque `ContactID`** and nothing else. It never reads a GuessWho ID string
   or a `localID` off it, and never persists one. <!-- [^contactid] -->
2. **Repository / package boundary → translation.** `ContactsRepository`
   translates a `ContactID` into a GuessWho ID (or, internally, a `localID`) to
   reach the engine. This is where the GuessWho-ID-vs-`localID` distinction below
   actually lives. <!-- [^repo-contact-id] -->
3. **Sidecar storage → GuessWho UUID.** Every note, tag, favorite, and link is
   keyed by the GuessWho UUID, wrapped in a `SidecarKey(kind: .contact, id:
   uuid)`. <!-- [^sidecarkey] -->

So the package-level truths still hold — the **GuessWho ID** is the durable,
cross-device identity; **`localID`** is a transient Contacts-framework handle
that must never be persisted, compared, or keyed-on as identity; sidecar data is
keyed by the GuessWho UUID. The migration adds one layer **above** them: the app
no longer touches either string. It sits on `ContactID`, and the repository does
the translation.

If you find yourself, **in the app target**, storing a `localID`, reading a
GuessWho ID off a contact, building a `[String: Contact]` map, or comparing two
contacts by a raw identifier — that is a bug. Hold and compare a `ContactID`;
fetch the `Contact` back through the repository. **In the package**, the same
rule that always held still does: never key sidecar data on `localID`; use the
GuessWho ID.

### The opaque-token contract (app layer)

The app obtains a `ContactID` ONLY from `repository.contactID(for: Contact)`
(`ContactID.init` is `package`, so the app cannot mint one itself), holds it,
compares it (e.g. as a diffable item identifier or a `Set` member), and hands it
back to `repository.contact(id:)` to fetch the real `Contact`. It CANNOT read any
field off it, so the token can never be misused as a "contact-light." It is also
deliberately NOT `Codable`: a `ContactID` carries the transient `localID`, so
persisting one would dangle after the next unification. Durable references
(favorites, link endpoints) persist the **bare GuessWho UUID** instead and
resolve it through `repository.contact(guessWhoID:)`. See the
[`ContactID`](#contactid-the-apps-identity-token) section for the full treatment.

### Package-caller contract (repository / engine layer)

Inside the package, the contact identity is the canonical lowercase UUID carried
in the contact's `guesswho://contact/<uuid>` URL. When an engine API requires a
contact identity, the repository provides that GuessWho UUID—normally wrapped in
`SidecarKey(kind: .contact, id: uuid)`—and retains that UUID for sidecar data and
any other durable reference. The app never does this translation itself; the
repository does it on the app's behalf when it resolves a `ContactID`.

`Contact.localID` exists because the Contacts adapter must use
`CNContact.identifier` to perform an immediate framework operation. It is not
part of the package's identity contract. It is still `public` on the transport
`Contact` struct (read by package fetch paths and a small set of blessed app
boundary tokens), but consumers must treat it as opaque and must not store it,
compare it, use it as a collection key, or pass it between application layers.

## `ContactID`: the app's identity token

`ContactID` is the canonical id shape for a contact **from the UI's
perspective**. The app keys list rows, navigation references, and fetch-by-id on
a `ContactID` and never sees the GuessWho ID / `localID` underneath.

### What it is

```swift
public struct ContactID: Hashable, Sendable {
    package let guessWhoID: String?   // canonical lowercase GuessWho UUID, nil until reconciled
    package let localID: String       // CNContact.identifier, always present

    var effectiveID: String { guessWhoID ?? localID }   // the single identity
}
```

- Both stored properties are `package`, so the **app target cannot read either
  one**. The conformances (`Hashable`, `Sendable`) are `public` so the app can
  put a `ContactID` in a diffable snapshot or a `Set`; the data stays sealed.
  <!-- [^contactid] -->
- `effectiveID` is `guessWhoID ?? localID`. **`==` and `hash(into:)` BOTH key on
  `effectiveID` and only on it**, so they cannot diverge — `ContactID` is a
  consistent `Hashable`. Two `ContactID`s for the same contact are equal
  regardless of how the underlying contact looks; the token carries **no display
  fields**. <!-- [^contactid-eq] -->
- `localID` is ALWAYS present, so a `ContactID` always materializes — including
  for a not-yet-reconciled contact (no `guesswho://` URL), which is identified by
  its `localID` and still appears in the list. `guessWhoID` is nil until the
  contact carries a valid GuessWho URL; once reconciliation mints or collapses
  identity, it populates and BECOMES the identity. <!-- [^contactid-init] -->

### The opaque-token contract

The app does exactly four things with a `ContactID`, and no more:

| The app… | …via | Notes |
| --- | --- | --- |
| **obtains** a token from a held `Contact` | `repository.contactID(for:)` | The only way to mint one — `ContactID.init` is `package`. <!-- [^contactid-for] --> |
| **compares / hashes** it | `==`, `Set`, diffable identifier | Identity-only; stable across reloads. |
| **resolves** it back to a `Contact` | `repository.contact(id:)` | O(1), reconcile-stable (see below). <!-- [^contact-id-accessor] --> |
| **resolves a bare GuessWho UUID** to a `Contact` | `repository.contact(guessWhoID:)` | For durable favorite / link endpoints read off disk. <!-- [^contact-guesswhoid] --> |

It NEVER reads `guessWhoID` / `localID` off the token, and NEVER persists a
`ContactID`. Why sealed-and-not-`Codable`:

- The app must not key on `localID` — it is transient (Apple re-mints it across
  unification / new device), so a persisted `ContactID` would dangle.
- A durable reference (a favorite, a link endpoint) persists the **bare GuessWho
  UUID** instead — favorites/links sync between devices, so their on-disk records
  are keyed on the stable UUID and resolved with `contact(guessWhoID:)`.
  <!-- [^contact-guesswhoid] -->

### How the UI identifies contacts now

- **List rows.** The list view controllers snapshot
  `NSDiffableDataSourceSnapshot<Section, ContactID>` — rows are keyed on the
  opaque `ContactID`. The cell provider fetches the row's `Contact` via
  `repository.contact(id:)` (an O(1) main-actor cache read) and renders it.
  Because `ContactID` carries no display data, content repaint is the view
  controller's own explicit `reconfigureItems` pass (it compares each row's
  freshly-fetched `Contact` against the one it last rendered); identity stays
  stable across reloads so rows don't flicker. <!-- [^contact-id-accessor] -->
- **Navigation.** A `ContactReference` carries a `ContactID` (not a `localID`),
  so a pushed/replaced detail re-resolves its `Contact` through the repository.
- **Fetch-by-id.** Detail views hold their `ContactID` and re-load the `Contact`
  off it; identity comparisons compare `ContactID`s (i.e. effective identity),
  never a raw `localID`.

### Reconcile-stable resolution

`repository.contact(id:)` resolves **GuessWho UUID first** (canonical identity
wins; a stale `localID` can never override a real UUID match) via a
`guessWhoID → localID` pointer index, else by `localID` directly:

```swift
public func contact(id: ContactID) -> Contact? {
    if let gw = id.guessWhoID, let lid = guessWhoIDToLocalID[gw] {
        return contactsByLocalID[lid]
    }
    return contactsByLocalID[id.localID]
}
```

The `localID` branch is **load-bearing**: a view captures a `ContactID` at
navigation whose `guessWhoID` is still nil, and the contact then reconciles
(gaining a `guessWhoID`). The captured token is immutable, so its `effectiveID`
is still the old `localID` — but `localID` is the one identifier that does NOT
move across the reconcile re-key, so resolution still finds the record. This is
why the app no longer threads a `localID` by hand to survive a reconcile.
<!-- [^contact-id-accessor] -->

A navigation reference or favorite holding a retired/unknown UUID resolves
through the repository; if it cannot resolve it returns `nil` → a non-crashing
"unavailable" state, never a wrong-contact fallback.

## Three distinct concepts: identity, relationships, and links

These terms deliberately describe different mechanisms. Do not use one as a
substitute for another.

### Contact identity

The **GuessWho ID** is the durable identity of a contact. It is written into a
Contacts URL field, syncs with the contact, and is reconciled by GuessWhoSync
when linked cards introduce zero, malformed, or competing IDs. It is the
package's canonical identity for a contact and the key for all sidecar data. The
app does not handle it directly — it holds a [`ContactID`](#contactid-the-apps-identity-token),
and the repository translates that to the GuessWho ID when it needs one. The one
durable GuessWho-ID string the app does touch is a favorite / link endpoint read
off disk, resolved through `repository.contact(guessWhoID:)`.

### Contacts relationships

A **Contacts relationship** is an Apple `CNContactRelation` value, such as a
field labelled “spouse” whose value is “Chris Smith.” Its target is only a
name string—there is no contact identifier in the Contacts data. GuessWho may
perform a best-effort lookup against cached contacts to make that relation
actionable in the UI, but the lookup can have zero, one, or several matches.
It does not create, imply, or persist a GuessWho-ID relationship.

### Sidecar contact links

A **sidecar contact link** is a package `Link` record joining two endpoints of
the form `SidecarKey(kind: .contact, id: <GuessWho UUID>)`. It is a durable,
specific hard link between two identified contacts. It is unrelated to
`CNContactRelation` name matching. If identity reconciliation collapses two
GuessWho IDs on one unified contact, GuessWhoSync rewrites affected sidecar
link endpoints from the losing ID to the canonical winning ID; it never rewrites
or interprets name-only Contacts relationships as hard links.

To classify which end of a fetched link is the OPENED contact (near) and which
is the far contact, the app asks the package — `SidecarKey.matches(_ contactID:)`
tests an endpoint key against `contactID.guessWhoID` (a `package` field). The app
never reads a bare GuessWho UUID to do this comparison itself; it passes a
`ContactID` and the package answers. (The app still resolves the FAR endpoint's
GuessWho UUID to a `Contact` via `contact(guessWhoID:)` — a durable link-endpoint
read, per the table above.)

## The two package-internal identifiers

These are the two identifiers the **package** works with underneath a
`ContactID`. The app sees neither directly — it holds a `ContactID` and the
repository translates to one of these (see [the three layers](#the-one-rule-three-layers)).

| | **GuessWho ID** | **localID** |
| --- | --- | --- |
| What it is | A UUID we mint | Apple's unified `CNContact.identifier` |
| Where it lives | A `guesswho://contact/<uuid>` URL on the contact | The `localID` field of `Contact` (and the sealed `localID` inside a `ContactID`) |
| Stable across devices? | **Yes** — same on every device after sync | **No** — different on each device |
| Persistable on one device? | **Yes** | **Yes**, but it may later resolve to a *different* unified contact (or stop resolving) when linked cards change |
| Who owns it | GuessWhoSync | The Contacts framework |
| Used for | Identity, sidecar keys, links, dedup — at the package/repository layer; the app touches a bare GuessWho UUID only as a durable favorite/link endpoint resolved via `contact(guessWhoID:)` | **Nothing as identity** — it's a transient lookup token. The Contacts adapter and the repository consume it internally; the app never reads it (it lives sealed inside `ContactID`). |

### Why `localID` cannot be identity

`localID` is the unified `CNContact.identifier` returned by the Contacts
framework. [^localid-source] Two properties make it unusable as a durable
identifier:

1. **It is device-local.** Apple documents `CNContact.identifier` as uniquely
   identifying the contact *"on the current device"* only — the same logical
   contact has a *different* `identifier` on each device after iCloud/CardDAV
   sync. A `localID` saved on your iPhone means nothing on your Mac. This alone
   is a complete reason it cannot be a cross-device key.
   [^plan-device-local][^apple-identifier]
2. **It is a *unified* identifier, and unification is not stable.** Apple does
   let you persist `CNContact.identifier` between launches on one device — but a
   `localID` is the identifier of a unified contact assembled from the
   per-account cards of one person (e.g. an iCloud card and an Exchange card).
   When the set of linked cards changes, a persisted `localID` may resolve to a
   *different* unified contact or stop resolving altogether; Apple even warns
   that `unifiedContact(withIdentifier:)` "may have a different identifier than
   you specify." So `localID` is safe to use only for an *immediate* re-fetch,
   never as a durable handle you store and compare. [^apple-unified]

The GuessWho ID solves both: it is minted once, written into the contact as a
URL that syncs losslessly via CardDAV, and chosen deterministically so every
device converges on the same value (see [Reconciliation](#reconciliation)).
[^plan-url]

### Why the GuessWho ID is a URL on the contact

We add one entry to the contact's `urlAddresses`:

- **label** `"GuessWho"`
- **value** `guesswho://contact/<uuid>` (no query string)

This is the only field the package writes onto the contact itself. A URL
field syncs through CardDAV without loss and is even visible in the system
Contacts app. There is no timestamp in the URL — convergence comes from the
reconciliation rule below, not from clocks. [^plan-url]

To recover the GuessWho ID from a `Contact`, scan `urlAddresses` for the
`guesswho://contact/` prefix, parse the suffix as a UUID, and canonicalize it
to lowercase. The package exposes this as `SidecarKey.forContact(_:)`.
[^sidecarkey]

## Unified contacts, not per-store contacts

The package never works with the per-account cards underneath a contact. Every
read returns Apple's **already-unified** contact: [^cnadapter]

- `fetchAll()` uses `enumerateContacts(with:)`. A `CNContactFetchRequest`
  returns unified results unless you set `unifyResults = false`, which the
  package never does.
- `fetch`, `save`, `delete`, image/thumbnail loads, and group-membership reads
  use `unifiedContact(withIdentifier:)` / `unifiedContacts(matching:)`.

There is no use of `CNContainer`, `unifyResults`, per-container predicates, or
the non-unified `contact(withIdentifier:)` anywhere in the package. Containers
and accounts are simply not part of our identity model. [^cnadapter]

**Consequence:** because we only ever see one unified contact per person, that
contact carries the union of every linked card's fields — including any
`guesswho://contact/…` URLs that were independently written to those cards.
When more than one such URL lands on a single unified contact, reconciliation
collapses them to one canonical GuessWho ID.

## Reconciliation

Reconciliation is the process that gives a contact exactly one canonical GuessWho
ID. It is **write-triggered, not run on open or at launch.** The package mints (or
collapses) a contact's GuessWho ID lazily, the FIRST time the user writes
GuessWho data to it — a note, a tag, a favorite, a link. The repository's
internal resolve-or-mint primitive (`resolveOrMintGuessWhoID(for:)`) is the
trigger: a WRITE that finds `id.guessWhoID == nil` runs reconcile on the
contact's `localID`, mints the URL, and writes the sidecar at the new UUID; an
already-reconciled contact's identity is stable and a write never perturbs it.
<!-- [^resolve-or-mint] -->

**Reads never reconcile and mint nothing.** `notes(for:)` / `links(for:)` /
`isFavorite(_:)` return empty/false when the contact has no GuessWho URL yet — an
unreconciled contact simply has no sidecar data, which is correct. Crucially,
**displaying a contact requires no GuessWho URL**: the UI holds a `ContactID`
(whose reconcile-stable `contact(id:)` resolution is all the view needs), so a
never-written contact renders fine and stays un-stamped until the user adds
GuessWho data. There is no "stamp every contact on open / at launch" sweep. <!-- [^reads-no-mint] -->

The whole-book sweep `reconcileContactIdentities()` is still `public`, but it is
a deliberate repair pass (e.g. a future background orphan/Case-D heal), **not**
something a caller must run before reading a contact. The single-contact entry
point `reconcileContactIdentity(localID:)` is now `internal` — **not
host-callable** — and is reached only through the package's own resolve-or-mint
write path. <!-- [^reconcile-single] -->

When reconcile does fire (on a write, or via the whole-book sweep), it runs the
same per-contact algorithm, dispatching on the number of *distinct, valid*
`guesswho://contact/…` URLs the contact carries: [^reconcile]

- **Case A — zero valid IDs.** Strip any malformed `guesswho://` URLs, mint a
  fresh UUID, write it as a new URL, save. (Adopt-on-first-write: the first time
  the user attaches GuessWho data to a contact, it gets an ID.) [^caseA]
- **Case B — exactly one valid ID, no malformed siblings.** No-op. [^reconcile]
- **Case C — one valid ID plus malformed siblings.** Keep the valid one, remove
  the malformed URLs, save. [^caseC]
- **Case D — two or more *different* valid IDs on one contact.** Sort the IDs as
  ASCII strings; the **lexicographically smallest wins.** Merge each loser's
  sidecar data into the winner's (a union — sidecar fields are keyed by
  per-instance UUIDs that can't collide), delete the loser sidecar files,
  rewrite any link endpoints that pointed at a loser to point at the winner,
  strip the loser and malformed URLs from the contact, and save. [^caseD]

Lex-smallest-wins is the package's single **first-writer-wins** rule (every
other field uses last-writer-wins). It needs no coordination and no clock: two
devices that independently minted an ID for the same contact will, after seeing
both URLs, deterministically pick the same winner and converge. [^plan-fww]

### `localID` enters only at the reconcile boundary, internally

Reconcile is the one place a `localID` is an input, and it is now a
package-**internal** step. The internal `reconcileContactIdentity(localID:)`
takes a `localID` purely to fetch the just-surfaced Contacts record so it can be
given (or reconciled onto) a GuessWho ID. [^reconcile-single] The app never calls
it — it writes a note/link/favorite through a `ContactID`-keyed repository method,
which resolves-or-mints internally. After that hand-off, nothing downstream is
keyed by `localID` — every sidecar, field, note, and link operation takes a
`SidecarKey` built from the GuessWho ID. [^sidecarkey-api] `localID` enters only
at the Contacts boundary and never propagates into GuessWho data or into the app.

## Where each identifier is allowed to appear

Read top-to-bottom as the three layers: the app keys on `ContactID`; the
repository translates; sidecar storage keys on the GuessWho UUID.

| Layer | Identifier | Notes |
| --- | --- | --- |
| **App code (lists, navigation, detail views)** | `ContactID` | Hold, compare, fetch with it. NEVER read a GuessWho ID / `localID` off it; NEVER persist it. The one durable string the app touches is a bare GuessWho UUID as a favorite/link endpoint, resolved via `contact(guessWhoID:)`. |
| **Repository boundary** (`ContactsRepository`) | `ContactID` → GuessWho ID / `localID` | Translates a `ContactID` to the GuessWho ID for sidecar work, or (internally) to `localID` for a Contacts-framework fetch. The layer that bridges the app's opaque token to the package's two identifiers. |
| `reconcileContactIdentity(localID:)` *(internal)* | `localID` in, GuessWho ID out | The bridge from Contacts handle to GuessWho identity. Reached only via resolve-or-mint on a write; not host-callable. |
| Contacts adapter (`ContactStoreProtocol`) | `localID` | Lookups into the Contacts framework only. Transient. |
| Sidecar storage, fields, notes | `SidecarKey(kind: .contact, id: <GuessWho UUID>)` | Never `localID`. |
| Links | `SidecarKey` endpoints | Endpoints rewritten to the winner on Case D. |

## Quick reference

**In the app:**

- **To identify a contact:** hold a `ContactID` (from
  `repository.contactID(for:)`). Compare/hash it, key list rows and navigation on
  it, fetch the `Contact` back with `repository.contact(id:)`. You do NOT need to
  reconcile first — an unreconciled contact still has a `ContactID` and renders
  fine; reads just return empty until the contact is written to.
- **To attach GuessWho data:** call the `ContactID`-keyed repository write
  (`addNote(for:…)`, `addLink(from:to:…)`, `toggleFavorite(_:)`, …). The write
  reconciles-or-mints internally on the first write — you never trigger, see, or
  name reconcile, and you never thread a `localID`.
- **To persist a durable reference** (favorite, link endpoint): store the bare
  GuessWho UUID string and resolve it via `repository.contact(guessWhoID:)`. Do
  NOT persist a `ContactID` (it carries the transient `localID`) and never store
  a `localID`.
- **Do not** read a GuessWho ID / `localID` off a `Contact` or `ContactID`, build
  a `[String: Contact]` map, or compare contacts by a raw identifier — compare
  `ContactID`s.

**In the package:**

- **To get a contact's identity:** `SidecarKey.forContact(contact)` → a
  `SidecarKey`. If it returns `nil`, the contact has not been reconciled yet —
  that is expected for any contact the user has not written to, and is NOT an
  error to fix before reading. A write reconciles it lazily.
- **To attach GuessWho data:** call the `addField` / `setField` / `addLink`
  family with that `SidecarKey`. Never with `localID`.
- **Do not** compare two contacts for "same person" by `localID`. Compare by
  GuessWho ID.

## Out of scope (v1)

- Cross-iCloud-account sync; single user, single iCloud account. [^plan-nongoals]
- Non-iCloud Contacts sources (Exchange, Google CardDAV) — best effort, may
  drift. [^plan-nongoals]

---

<!-- Citations — code symbols (not line numbers), PLAN.md section line ranges, and Apple docs (external URLs). -->
<!-- [^localid-source]: [CNContactStoreAdapter.toContact maps c.identifier -> Contact.localID](../Sources/GuessWhoSync/CNContactStoreAdapter.swift:CNContactStoreAdapter.toContact) -->
<!-- [^plan-device-local]: [PLAN.md §3.1 — CNContact.identifier is device-local](../PLAN.md:41-43) -->
<!-- [^apple-identifier]: [Apple — CNContact.identifier: "uniquely identifies a contact on the device"; "can be persisted between the app launches"](https://developer.apple.com/documentation/contacts/cncontact/identifier) -->
<!-- [^apple-unified]: [Apple — unifiedContact(withIdentifier:keysToFetch:): "Due to unification, the returned contact may have a different identifier than you specify"](https://developer.apple.com/documentation/contacts/cncontactstore/unifiedcontact(withidentifier:keystofetch:)) -->
<!-- [^plan-url]: [PLAN.md §3.2 — the GuessWho URL](../PLAN.md:47-54) -->
<!-- [^sidecarkey]: [SidecarKey.forContact / parseGuessWhoContactURL](../Sources/GuessWhoSync/SidecarKey.swift:SidecarKey) -->
<!-- [^cnadapter]: [CNContactStoreAdapter — fetchAll uses enumerateContacts (unified by default); all other reads use unifiedContact/unifiedContacts](../Sources/GuessWhoSync/CNContactStoreAdapter.swift:CNContactStoreAdapter) -->
<!-- [^reconcile]: [GuessWhoSync.reconcile(contact:) — case dispatch on distinct valid GuessWho ID count](../Sources/GuessWhoSync/GuessWhoSync.swift:reconcile) -->
<!-- [^caseA]: [GuessWhoSync.handleCaseA — mint a fresh UUID](../Sources/GuessWhoSync/GuessWhoSync.swift:handleCaseA) -->
<!-- [^caseC]: [GuessWhoSync.handleCaseC — strip malformed URLs](../Sources/GuessWhoSync/GuessWhoSync.swift:handleCaseC) -->
<!-- [^caseD]: [GuessWhoSync.handleCaseD — lex-smallest winner, merge + delete losers](../Sources/GuessWhoSync/GuessWhoSync.swift:handleCaseD) -->
<!-- [^plan-fww]: [PLAN.md Core Semantics §5 — FWW lex-smallest convergence](../PLAN.md:35) -->
<!-- [^reconcile-single]: [GuessWhoSync.reconcileContactIdentity(localID:) — now `internal` (Stage 6e); fetches by localID, returns a ContactOutcome keyed by GuessWho ID; reached only via the repository's resolve-or-mint write path](../Sources/GuessWhoSync/GuessWhoSync.swift:reconcileContactIdentity) -->
<!-- [^sidecarkey-api]: [GuessWhoSync sidecar/field/link API takes SidecarKey, not localID](../Sources/GuessWhoSync/GuessWhoSync.swift:addField) -->
<!-- [^plan-nongoals]: [PLAN.md §2 Non-goals (v1)](../PLAN.md:19-25) -->
<!-- [^contactid]: [ContactID — opaque identity token; both stored props (guessWhoID?/localID) are `package`, conformances public](../Sources/GuessWhoSync/ContactID.swift:ContactID) -->
<!-- [^contactid-eq]: [ContactID.== / hash(into:) BOTH key on effectiveID (= guessWhoID ?? localID); no display fields](../Sources/GuessWhoSync/ContactID.swift:ContactID) -->
<!-- [^contactid-init]: [ContactID.init(contact:) — package; always materializes (localID always present); guessWhoID via SidecarKey.forContact, nil pre-reconcile](../Sources/GuessWhoSync/ContactID.swift:ContactID) -->
<!-- [^contactid-for]: [ContactsRepository.contactID(for:) — the only sanctioned way for the app to mint a ContactID from a held Contact](../Sources/GuessWhoSync/ContactsRepository.swift:contactID) -->
<!-- [^contact-id-accessor]: [ContactsRepository.contact(id:) — O(1) resolve, guessWhoID-first via the guessWhoIDToLocalID pointer index else by localID; reconcile-stable for a captured token](../Sources/GuessWhoSync/ContactsRepository.swift:contact) -->
<!-- [^contact-guesswhoid]: [ContactsRepository.contact(guessWhoID:) — public resolver for a bare GuessWho UUID (favorite/link endpoint); pointer hop, no confirm-guard; ContactID is not Codable for durable storage](../Sources/GuessWhoSync/ContactsRepository.swift:contact) -->
<!-- [^repo-contact-id]: [ContactsRepository — translates a ContactID to GuessWho ID / localID at the package boundary; the app never does this](../Sources/GuessWhoSync/ContactsRepository.swift:ContactsRepository) -->
<!-- [^resolve-or-mint]: [ContactsRepository.resolveOrMintGuessWhoID(for:) — internal; a WRITE with id.guessWhoID == nil reconciles on localID and mints; an already-reconciled id returns its UUID, minting nothing](../Sources/GuessWhoSync/ContactsRepository.swift:resolveOrMintGuessWhoID) -->
<!-- [^reads-no-mint]: [ContactsRepository.notes(for:)/links(for:)/isFavorite(_:) — return empty/false when id.guessWhoID is nil; reads never reconcile or mint](../Sources/GuessWhoSync/ContactsRepository.swift:notes) -->
