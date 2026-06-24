# Contact Identity: GuessWho ID vs. localID

This document is the source of truth for how GuessWhoSync identifies a contact.
Read it before writing any code that fetches, stores, links, or compares
contacts.

## The one rule

**Callers identify a contact by its GuessWho ID and nothing else.**

The GuessWho ID is a UUID the package mints and owns. It is stable across
devices and across time. Everything a caller does to attach GuessWho data —
notes, tags, favorites, links — is keyed by this ID (wrapped in a `SidecarKey`).
There is exactly one other identifier in the system, `localID`, and it is an
**internal Contacts-framework handle that callers must not persist, compare, or
treat as identity.**

If you find yourself storing a `localID`, using it as a dictionary key for
GuessWho data, or comparing two contacts by `localID`, that is a bug. Use the
GuessWho ID.

## The two identifiers

| | **GuessWho ID** | **localID** |
| --- | --- | --- |
| What it is | A UUID we mint | Apple's unified `CNContact.identifier` |
| Where it lives | A `guesswho://contact/<uuid>` URL on the contact | The `localID` field of `Contact` |
| Stable across devices? | **Yes** — same on every device after sync | **No** — different on each device |
| Stable across time on one device? | **Yes** | **No** — changes when Apple re-unifies |
| Who owns it | GuessWhoSync | The Contacts framework |
| Callers use it for | Identity, sidecar keys, links, dedup | **Nothing** — it's a transient lookup token |

### Why `localID` cannot be identity

`localID` is the unified `CNContact.identifier` returned by the Contacts
framework. [^localid-source] Two properties make it unusable as a durable
identifier:

1. **It is device-local.** The same logical contact has a *different*
   `identifier` on each device after iCloud/CardDAV sync. A `localID` saved on
   your iPhone means nothing on your Mac. [^plan-device-local]
2. **It is a *unified* identifier, and unification is not permanent.** Apple
   merges the per-account cards of one person (e.g. an iCloud card and an
   Exchange card) into a single *unified contact* with its own identifier. When
   the set of linked cards changes — a card is added, removed, or re-linked —
   the unified identifier can change. So even on a single device, `localID` is
   not guaranteed to be the same token tomorrow.

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

Reconciliation is the process that guarantees every contact has exactly one
GuessWho ID. Hosts call `reconcileContactIdentities()` (sweep all contacts,
e.g. at launch and on foreground) or `reconcileContactIdentity(localID:)` (one
contact). Both run the same per-contact algorithm, dispatching on the number of
*distinct, valid* `guesswho://contact/…` URLs the contact carries:
[^reconcile]

- **Case A — zero valid IDs.** Strip any malformed `guesswho://` URLs, mint a
  fresh UUID, write it as a new URL, save. (Adopt-on-first-sight: the first
  time the package meets a contact, it gives it an ID.) [^caseA]
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

### `reconcileContactIdentity(localID:)` is the one place `localID` is an input

This is deliberate and instructive. The single-contact entry point takes a
`localID` purely to fetch the just-surfaced Contacts record so it can be given
(or reconciled onto) a GuessWho ID. [^reconcile-single] After that hand-off,
nothing downstream is keyed by `localID` — every sidecar, field, note, and link
operation takes a `SidecarKey` built from the GuessWho ID. [^sidecarkey-api]
`localID` enters only at the Contacts boundary and never propagates into GuessWho
data.

## Where each identifier is allowed to appear

| Layer | Identifier | Notes |
| --- | --- | --- |
| Contacts adapter (`ContactStoreProtocol`) | `localID` | Lookups into the Contacts framework only. Transient. |
| `reconcileContactIdentity(localID:)` | `localID` in, GuessWho ID out | The bridge from Contacts handle to GuessWho identity. |
| Sidecar storage, fields, notes | `SidecarKey(kind: .contact, id: <GuessWho UUID>)` | Never `localID`. |
| Links | `SidecarKey` endpoints | Endpoints rewritten to the winner on Case D. |
| Caller code (the app) | GuessWho ID | Persist, compare, and dedup on this only. |

## Quick reference

- **To get a contact's identity:** `SidecarKey.forContact(contact)` → a
  `SidecarKey`. If it returns `nil`, the contact has not been reconciled yet —
  run reconciliation first.
- **To attach GuessWho data:** call the `addField` / `setField` / `addLink`
  family with that `SidecarKey`. Never with `localID`.
- **To persist a reference to a contact** (e.g. in your own storage): store the
  GuessWho UUID string. Never store a `localID`.
- **Do not** compare two contacts for "same person" by `localID`. Compare by
  GuessWho ID.

## Out of scope (v1)

- Cross-iCloud-account sync; single user, single iCloud account. [^plan-nongoals]
- Non-iCloud Contacts sources (Exchange, Google CardDAV) — best effort, may
  drift. [^plan-nongoals]

---

<!-- Citations — code symbols (not line numbers) and PLAN.md section line ranges. -->
<!-- [^localid-source]: [CNContactStoreAdapter.toContact maps c.identifier -> Contact.localID](../Sources/GuessWhoSync/CNContactStoreAdapter.swift:CNContactStoreAdapter) -->
<!-- [^plan-device-local]: [PLAN.md §3.1 — CNContact.identifier is device-local](../PLAN.md:39-45) -->
<!-- [^plan-url]: [PLAN.md §3.2 — the GuessWho URL](../PLAN.md:47-54) -->
<!-- [^sidecarkey]: [SidecarKey.forContact / parseGuessWhoContactURL](../Sources/GuessWhoSync/SidecarKey.swift:SidecarKey) -->
<!-- [^cnadapter]: [CNContactStoreAdapter — fetchAll uses enumerateContacts (unified by default); all other reads use unifiedContact/unifiedContacts](../Sources/GuessWhoSync/CNContactStoreAdapter.swift:CNContactStoreAdapter) -->
<!-- [^reconcile]: [GuessWhoSync.reconcile(contact:) — case dispatch on distinct valid GuessWho ID count](../Sources/GuessWhoSync/GuessWhoSync.swift:reconcile) -->
<!-- [^caseA]: [GuessWhoSync.handleCaseA — mint a fresh UUID](../Sources/GuessWhoSync/GuessWhoSync.swift:handleCaseA) -->
<!-- [^caseC]: [GuessWhoSync.handleCaseC — strip malformed URLs](../Sources/GuessWhoSync/GuessWhoSync.swift:handleCaseC) -->
<!-- [^caseD]: [GuessWhoSync.handleCaseD — lex-smallest winner, merge + delete losers](../Sources/GuessWhoSync/GuessWhoSync.swift:handleCaseD) -->
<!-- [^plan-fww]: [PLAN.md Core Semantics §5 — FWW lex-smallest convergence](../PLAN.md:35) -->
<!-- [^reconcile-single]: [GuessWhoSync.reconcileContactIdentity(localID:) — fetches by localID, returns a ContactOutcome keyed by GuessWho ID](../Sources/GuessWhoSync/GuessWhoSync.swift:reconcileContactIdentity) -->
<!-- [^sidecarkey-api]: [GuessWhoSync sidecar/field/link API takes SidecarKey, not localID](../Sources/GuessWhoSync/GuessWhoSync.swift:addField) -->
<!-- [^plan-nongoals]: [PLAN.md §2 Non-goals (v1)](../PLAN.md:19-25) -->
