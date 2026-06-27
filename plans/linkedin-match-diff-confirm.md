# Plan: LinkedIn match → diff → confirm (app process)

## Status (2026-06-26) — MOSTLY BUILT

The match → diff → confirm → **save** flow is built and working end-to-end for
all fields EXCEPT the photo (the contact-image write path is still a no-op — the
one remaining piece). What ships today:

- ✅ Package matching (`matchLinkedIn`: URL → email → name) + `LinkedInProfile`
  model + URL normalizer, unit-tested.
- ✅ Decode the handoff in `GuessWhoSceneDelegate` and match.
- ✅ `LinkedInDiff` builder + `LinkedInConfirmView` (per-field checkboxes,
  existing-left/incoming-right, unchanged rows de-emphasized, merge-not-replace
  for emails/websites, scheme-insensitive URL dedup, hides the `guesswho://`
  identity URL, Escape-cancel / accent-checkmark-save).
- ✅ Save on Confirm via `ContactsRepository.applyLinkedIn(profile:to:fields:)
  async -> Contact`: CNContact fields merge-saved (default labels, LinkedIn
  social profile stored as USERNAME); about/location stored as **upsertable
  named sidecar fields** (NOT append-only notes), prefixed "LinkedIn ".
- ✅ **Beyond the original plan** (added during the build):
  - Sidecar fields are displayed, editable, and deletable in `ContactDetailView`
    (read-mode context menu + in-edit-mode "Custom Fields" section; value
    editable, key read-only). `FieldsStore` view model + `editField`/`deleteField`.
  - New `multilineNote` `SidecarFieldType` — "LinkedIn About" is multi-line,
    "LinkedIn Location" single-line; `upsertField` can change a field's type by
    replace.
  - Edit mode uses a single accent checkmark Done (no Cancel/Save) since some
    edits commit immediately.
  - The old unified "Activity" timeline was split into Notes / Linked Contacts /
    Linked Organizations / Linked Events sections.
  - The open contact card refreshes after a save (`.linkedInImportDidSave`).
- ⏳ **Photo write path — NOT built.** The `.photo` field is accepted but
  applying it is a no-op. This is the net-new package work (`apply()` skips
  image data); see the storage split + build order below.
- ⏳ No-match → new-contact screen: deferred (no create flow in the app yet).

Companion docs: `docs/linkedin-safari-extension.md` (mechanism),
`plans/linkedin-safari-extension.md` (overall feature).

## Matching rules (user-specified)

Try in priority order; first hit wins (most precise first):

**All matching logic is PACKAGE-side** (in `ContactsRepository`/`GuessWhoSync`),
never in the app — consistent with `contactIDs(matchingEmail:)` /
`contactIDs(named:)`. The app calls a package matcher; it owns no matching rules.

1. **LinkedIn URL** (most precise — a near-unique identifier). Match a contact
   whose `socialProfiles` or `urlAddresses` contains the LinkedIn profile.
   - Match the **full profile URL** (`contactInfo.profileUrl`,
     normalized — strip scheme/`www.`/trailing slash, case-insensitive), AND
   - match just the **username/slug** (`/in/<slug>`), so a stored URL with a
     different format (mobile, query params, trailing path) still matches.
   - **Net-new package primitive:** add `contactIDs(matchingLinkedInURL:)` (and
     an index, mirroring `contactsByEmail`) to `ContactsRepository`, with tests.
2. **Email.** Any parsed `contactInfo.emails` ↔ a contact's email, via
   `contactIDs(matchingEmail:)` (case-insensitive, returns ALL matches).
3. **Display name.** `contactIDs(named: fullName)` / `lookupByDisplayName()`.
4. **Else → no match** (defer to a future new-contact screen).

A single package entry point — e.g. `matchLinkedIn(profile:) -> [ContactID]` or
a thin matcher type in `GuessWhoSync` — runs tiers 1→3 in order and returns the
first non-empty tier. The app just presents whatever it returns.

Multiple matches at a given tier: take the single best and show it in the
confirm dialog; if several, note it and let the user proceed with the chosen one
(full disambiguation picker is a later refinement, not v1).

## The confirm dialog — per-field diff with checkboxes

Layout: **left = existing contact value, right = incoming LinkedIn value.** Each
field row has a **checkbox** (default on) so the user can exclude individual
fields from the sync (e.g. keep everything except job title). Confirm applies
only the checked fields; Cancel writes nothing.

### Field rows (existing `Contact` field ← parsed field)

| Row | Existing (`Contact`) | Incoming (parsed) | Notes |
| --- | --- | --- | --- |
| Photo | contact image (lazy-loaded) | `photo.dataURL` bytes | side-by-side thumbnails |
| Name | `givenName` + `familyName` | `fullName` (split) | checkbox ON by default like the rest |
| Job title | `jobTitle` | `title` | |
| Organization | `organizationName` | `org` | |
| Location | (sidecar location field) | `location` | verbatim string |
| About | (sidecar note) | `about` | → a `ContactNote` |
| Email(s) | `emailAddresses` | `contactInfo.emails` | merge/dedupe; show new ones |
| Website(s) | `urlAddresses` | `contactInfo.websites` | merge/dedupe |
| LinkedIn URL | `socialProfiles` (LinkedIn) | `contactInfo.profileUrl` | ensure present |

Rows where existing == incoming (no change) can be shown muted/collapsed or
hidden — decide during implementation; default to showing changed rows
prominently and unchanged ones de-emphasized.

## Architecture (app process)

```
handleLinkedInHandoff(payload JSON)
  → decode → LinkedInProfile (Swift model)
  → match (ContactsRepository: email → name → none)
  → build [DiffRow] (existing vs incoming, per field)
  → present LinkedInConfirmView (SwiftUI) with checkboxes
       Confirm → apply checked rows  (SAVE — scope below)
       Cancel  → nothing
```

**Package (`Sources/GuessWhoSync/`)** — model + ALL matching:
- `LinkedInProfile.swift` — `Codable`, `Sendable` model of the parsed payload
  (fullName, title, org, location, about, contactInfo{emails,websites,profileUrl},
  photo{dataURL,contentType,byteLength}, sourceUrl/slug). Package-vended so the
  matcher can take it as input.
- LinkedIn URL matching: `contactIDs(matchingLinkedInURL:)` + an index on
  `ContactsRepository` (mirrors `contactsByEmail`), plus a single
  `matchLinkedIn(profile:) -> [ContactID]` entry point that runs URL → email →
  name and returns the first non-empty tier. Unit-tested in
  `Tests/GuessWhoSyncTests`.
- A LinkedIn-URL normalizer (strip scheme/`www.`/trailing slash; extract
  `/in/<slug>`) — pure, unit-testable.

**App (`App/GuessWho/`)** — decode + present only (NO matching rules):
- Decode the handoff JSON into the package `LinkedInProfile`.
- `LinkedInConfirmView.swift` — SwiftUI diff dialog (left/right + per-row
  checkbox), hosted in a `UIHostingController`, presented from the scene delegate
  (same pattern as `ContactDetailView`/`EventDetailView`).
- `LinkedInDiff.swift` (app) — builds `[DiffRow]` for display from the resolved
  `Contact` + the package `LinkedInProfile` (presentation concern, app-side).

`GuessWhoSceneDelegate` decodes the payload, calls the package matcher via
`GuessWhoAppDelegate.contactsRepository`, then presents the dialog.

## Scope decisions (CONFIRMED 2026-06-26)

1. **Confirm SAVES for real** (all chosen fields, this phase). This includes the
   net-new photo write path — see "Storage split" below.
2. **No-match → defer.** There's no new-contact screen in the app yet, so the
   no-match case just shows the parsed preview + "no matching contact found";
   real creation is a later step.
3. **All checkboxes ON by default** (including Name); the user can disable any.
4. **Unchanged rows: de-emphasized** (shown, muted).

## Storage split — CNContact vs. sidecar (settled against `apply()`)

`CNContactStoreAdapter.apply()` (the `saveContact` write path) writes these to
CNContact, so they save via `saveContact`:

| Field | Storage | How |
| --- | --- | --- |
| Name (given/family) | CNContact | `saveContact` |
| Job title | CNContact | `saveContact` |
| Organization | CNContact | `saveContact` |
| Emails | CNContact | `saveContact` (merge/dedupe into `emailAddresses`) |
| Websites | CNContact | `saveContact` (merge/dedupe into `urlAddresses`) |
| LinkedIn URL | CNContact | `saveContact` (ensure in `socialProfiles`) |

**Identity-URL guard (must not regress):** the diff UI hides the internal
`guesswho://contact/<uuid>` URL from the Websites column (it's sidecar plumbing).
That filter is DISPLAY-ONLY. The save MUST merge new websites onto the
contact's **real** `urlAddresses` (which still contains the `guesswho://`
identity URL) — never reconstruct `urlAddresses` from the filtered/displayed
set. Dropping that URL would orphan the contact's sidecar data
(see `docs/contact-identity.md`).

`apply()` deliberately does NOT write two things, so they need other paths:

| Field | Storage | Why / How |
| --- | --- | --- |
| About / bio | **Sidecar** (`ContactNote`) | `CNContactNoteKey` is entitlement-gated — that's why GuessWho keeps notes in the sidecar. `addNote`. |
| Location (verbatim) | **Sidecar** | CNContact has no clean free-text locality slot; store the verbatim string in a sidecar field. |
| Photo bytes | **CNContact image**, via a **net-new write path** | `apply()` skips `imageData` ("owned by the caller via a separate path", lines 620-624). Requires a new package API: fetch-with-image-keys + a separate image-including save. This is the heaviest piece of the phase. |

So Confirm fans out to THREE write paths: `saveContact` (the bulk of fields),
`addNote` (bio; possibly the location field too), and the new contact-image
write path (photo).

## Build order

1. ✅ **Package:** `LinkedInProfile` model + LinkedIn-URL normalizer +
   `contactIDs(matchingLinkedInURL:)` + `matchLinkedIn(profile:)`, unit-tested.
2. ✅ **App:** decode the handoff into `LinkedInProfile` and match.
3. ✅ `LinkedInDiff` builder (now also reads existing sidecar values so re-import
   shows the existing side and marks unchanged rows).
4. ✅ `LinkedInConfirmView` dialog (per-field checkboxes, unchanged de-emphasized).
5. ✅ **Save on Confirm** via `applyLinkedIn` — CNContact merge-save + upsert
   sidecar fields. (Note: bio/location are UPSERT FIELDS, not `addNote` as
   originally written here.)
6. ⏳ **Photo write path (THE remaining piece).** Net-new package work: a
   `setImageData`-shaped API that re-fetches with image keys and issues an
   image-including save (since `apply()` skips image data), then wire the
   `.photo` field in `applyLinkedIn` to write the decoded bytes.
7. (Later) no-match create-new screen; `.blob` previous-photo; iOS target.

## Out of scope here (still later)

The new-contact creation screen, the `.blob` previous-photo work, and the iOS
target — all later, per the overall plan. (The contact-image WRITE path was in
scope for this phase but remains the one unbuilt item — see step 6.)
