# GuessWho

## Product principle: sidecar is an implementation detail, never a user-facing concept

From the user's perspective there is **one** kind of contact and **one** kind
of event. The sidecar is how we persist GuessWho-only data (notes, tags,
links, favorites) for records whose source-of-truth lives in Contacts.app /
Calendar.app, but the user never sees, names, or chooses "sidecar" anywhere
in the UI. We hide the seam.

Concrete consequences — do NOT add UI that violates these, and remove any you
find:

- **Never offer "Unlink from Calendar" / "Unlink from Contacts."** Unlinking
  surfaces the sidecar/EventKit boundary as a user concept. The only way for
  a user to remove GuessWho data is to delete the record outright; the
  underlying Calendar.app / Contacts.app entry is unaffected. The
  `unlinkEvent` / `unlinkContact` service methods may still exist for
  migration/repair, but no UI should call them.
- **Never offer a "pick from existing Calendar event" / "pick from existing
  Contact" flow.** Adoption happens automatically when the user opens a row
  the EventKit/Contacts adapter surfaces — `EventDetailView` mints the
  sidecar on first load via the adopt-on-load path in `reload()`. No
  user-facing "link to a calendar event" or "link to a contact" affordance.
- **"Add event" / "Add contact" always creates a brand-new GuessWho record.**
  It must not present a picker over EventKit / Contacts results.
- The detail view's title, fields, and actions read identically whether the
  record is sidecar-only, EventKit-only (ephemeral, pre-adoption), or
  EventKit+sidecar. List rows use a single icon per kind (one icon for
  events, one for contacts) — never branch icon on `isLinked` /
  source-of-truth.
- Internal vocabulary stays internal. Strings like "sidecar," "reconcile,"
  and "GuessWho" (as a noun for our private records) MUST NOT appear in
  any user-facing label, message, or banner. The carve-out is **debug-mode
  surfaces** (the contact-row reconcile checkmark, the contact detail Debug
  section, debug toggle copy in Settings, OS-level NSLog breadcrumbs) —
  those are for the developer, not the user, and the vocabulary helps
  diagnose issues. Anything visible without flipping the debug switch
  must use plain-language: "contact," "event," "notes," "tags," "storage,"
  etc.

When in doubt: if a label, button, or sheet uses the word "sidecar,"
"link," "unlink," "EventKit," "Calendar event," or "existing contact,"
it's almost certainly wrong. Rephrase in terms of the user's mental model
(events, contacts, notes, tags) or remove it.

## Repo layout

- `Sources/GuessWhoSync/` — the storage + sync engine (Swift Package).
  Sidecar storage, EventKit/Contacts adapters, model types (`Event`,
  `Contact`, `ContactLink`, `ContactNote`, `EventTag`, `SidecarKey`).
- `App/GuessWho/` — the app target. SwiftUI + UIKit (Catalyst 3-column
  shell, iPhone tab-bar shell). Detail views, list view controllers,
  scene delegate.
- `Tests/GuessWhoSyncTests/` — XCTest suite for the sync package.

## Identity: the GuessWho URL and unified contacts

This is how the package answers "which contact is this?" across stores and
devices. Read this before touching reconciliation.

> **Full reference:** [`docs/contact-identity.md`](docs/contact-identity.md) —
> the source of truth for GuessWho ID vs. `localID`, why callers must identify a
> contact *only* by its GuessWho ID, and how that relates to Contacts
> identifiers and unified contacts. The summary below is a digest of that doc.

### One identity, not one per store

We do **not** treat Contacts accounts (iCloud, Exchange, Google, On-My-Mac) as
separate. Every read returns Apple's already-unified contact, never the
per-account "linked cards" underneath it: list reads use
`enumerateContacts(with:)` (a `CNContactFetchRequest` returns unified results
unless you set `unifyResults = false`, which we never do), and point reads,
group-membership reads, saves, and deletes use
`unifiedContact(withIdentifier:)` / `unifiedContacts(matching:)`. There is no
use of `CNContainer`, `unifyResults`, or the non-unified
`contact(withIdentifier:)` anywhere in the package; container is not part of
our identity model at all. [^cnadapter]

`Contact.localID` is therefore the **unified** `CNContact.identifier`. We do
not use it as our cross-device key, because `CNContact.identifier` is
device-local — the same logical contact has a different identifier on each
device after iCloud sync. [^plan-identity]

### The GuessWho URL is our identity

For every contact we touch, we mint our own stable UUID and store it as a URL
on the contact itself:

- **label** `"GuessWho"`, **value** `guesswho://contact/<uuid>` (no query
  string). It's the only field we add to the contact; it syncs losslessly via
  CardDAV and is visible in Contacts.app. [^plan-url]

Recovering the identity is just: scan `Contact.urlAddresses` for an entry whose
value starts with `guesswho://contact/`, parse the suffix as a UUID, lowercase
it (UUIDs are canonicalized to lowercase at every boundary — parse, format,
compare, on-disk filename), and build `SidecarKey(kind: .contact, id: uuid)`.
[^sidecarkey]

### Reconciling a (possibly unified) contact

`reconcileContactIdentities()` sweeps every contact;
`reconcileContactIdentity(localID:)` does one. Both run the same per-contact
algorithm, which inspects every `guesswho://contact/…` URL on the contact and
sorts the distinct valid UUIDs into one of four cases: [^reconcile]

- **Case A — zero valid UUIDs.** Strip any malformed `guesswho://` URLs, mint a
  fresh UUID, append `guesswho://contact/<new>`, save. This is adopt-on-first-
  sight. [^caseA]
- **Case B — exactly one valid UUID, no malformed siblings.** No-op. (Fast path
  in `reconcile(contact:)`.) [^reconcile]
- **Case C — one valid UUID + malformed siblings.** Keep the valid one, remove
  the malformed entries, save. [^caseC]
- **Case D — two or more *different* valid UUIDs on one contact.** This is the
  unification case. Sort the UUIDs as ASCII; the **lex-smallest wins**. Fold
  each loser's sidecar into the winner's (rebase the loser envelope onto the
  winner's `entityID`, then per-cell LWW merge — effectively a union, since
  sidecar fields are keyed by per-instance UUIDs that can't collide), write the
  winner sidecar, delete the loser sidecar files, strip the loser + malformed
  URLs from the contact, save. [^caseD]

Lex-smallest-wins is the package's one **FWW** (first-writer-wins) rule, the
lone exception to LWW: two devices that independently minted a UUID for the same
contact converge on the same winner with no further writes and no clock
dependency. [^plan-fww]

### Why a single contact ends up with multiple UUIDs (→ Case D)

Case D fires whenever one unified contact carries more than one
`guesswho://contact/<uuid>` URL. The package only ever stamps the unified
contact, so it never produces two UUIDs on its own; multiple UUIDs always arrive
from the outside. The documented primary cause is two devices each minting a
UUID for the same contact offline, before CardDAV sync converges and merges both
URLs onto one card. (A secondary path: per-account cards that were each stamped
by some *external* writer before Contacts.app unified them — the package itself
can't create this, since it only sees the unified contact.) Either way the
reconciler collapses the URLs to one canonical identity. [^plan-fww]

### Links follow the winner

When Case D collapses loser `L` into winner `W`, any link sidecar whose
`endpointA`/`endpointB` was `(.contact, L)` is rewritten to `(.contact, W)`.
The rewrite runs once per pass over the union of every Case-D mapping, so a link
straddling two collapses is written exactly once; the touched link UUIDs are
reported in `ContactOutcome.rewrittenLinkIDs`. [^rewrite]

### What is NOT reconciled here

- **Orphan sidecars** (a sidecar UUID no contact carries) are *detected* and
  reported in `IdentityReconcileReport.orphanSidecars` by the all-contacts
  sweep, but never auto-deleted. The single-contact entry point does not
  populate orphans — that needs the global set of carried UUIDs. [^orphan]
- **On-disk file conflicts** are a separate concern handled by
  `reconcileSidecars()` (NSFileVersion per-file conflict resolution), not by
  identity reconciliation. [^sidecarrecon]
- **Cross-iCloud-account sync and non-iCloud sources** (Exchange, Google
  CardDAV) are explicit v1 non-goals — "best effort, may drift." [^plan-nongoals]

<!-- [^cnadapter]: [CNContactStoreAdapter — every fetch uses the unified API; localID = CNContact.identifier](Sources/GuessWhoSync/CNContactStoreAdapter.swift:CNContactStoreAdapter) -->
<!-- [^plan-identity]: [PLAN.md §3.1 — CNContact.identifier is device-local](PLAN.md:39-45) -->
<!-- [^plan-url]: [PLAN.md §3.2 — the GuessWho URL](PLAN.md:47-54) -->
<!-- [^sidecarkey]: [SidecarKey.parseGuessWhoContactURL / forContact](Sources/GuessWhoSync/SidecarKey.swift:SidecarKey) -->
<!-- [^reconcile]: [GuessWhoSync.reconcile(contact:) — case dispatch on distinct valid UUID count](Sources/GuessWhoSync/GuessWhoSync.swift:reconcile) -->
<!-- [^caseA]: [GuessWhoSync.handleCaseA](Sources/GuessWhoSync/GuessWhoSync.swift:handleCaseA) -->
<!-- [^caseC]: [GuessWhoSync.handleCaseC](Sources/GuessWhoSync/GuessWhoSync.swift:handleCaseC) -->
<!-- [^caseD]: [GuessWhoSync.handleCaseD — lex-smallest winner, merge + delete losers](Sources/GuessWhoSync/GuessWhoSync.swift:handleCaseD) -->
<!-- [^plan-fww]: [PLAN.md Core Semantics §5 + §3.3 Case D — FWW lex-smallest convergence](PLAN.md:35) -->
<!-- [^rewrite]: [GuessWhoSync.rewriteLinkEndpoints + IdentityReconcileReport.ContactOutcome.rewrittenLinkIDs](Sources/GuessWhoSync/GuessWhoSync.swift:rewriteLinkEndpoints) -->
<!-- [^orphan]: [GuessWhoSync.reconcileContactIdentities — orphan detection](Sources/GuessWhoSync/GuessWhoSync.swift:reconcileContactIdentities) -->
<!-- [^sidecarrecon]: [GuessWhoSync.reconcileSidecars — NSFileVersion conflict path](Sources/GuessWhoSync/GuessWhoSync.swift:reconcileSidecars) -->
<!-- [^plan-nongoals]: [PLAN.md §2 Non-goals (v1)](PLAN.md:19-25) -->

## Platforms

- **Mac Catalyst:** 3-column `UISplitViewController` shell driven by
  `GuessWhoSceneDelegate`. Sidebar → list (supplementary) → detail
  (secondary). Selecting a row REPLACES the secondary column.
- **iPhone / iPad (non-Catalyst):** tab-bar shell. Selecting a row PUSHES
  the detail onto the active tab's nav stack.

Both shells host the same SwiftUI detail views
(`ContactDetailView`, `EventDetailView`) inside `UIHostingController`s.

## Conventions

- No `git -C` — operate from the worktree.
- Use `grep`, not `rg`.
- Never silence an error by commenting it out; fix the underlying cause.
- Slow is smooth; smooth is fast. Be methodical.
