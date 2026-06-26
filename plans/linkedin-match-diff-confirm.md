# Plan: LinkedIn match → diff → confirm (app process)

## Status (2026-06-26)

Planning. The parse + transfer layer is done and proven end-to-end (text,
contact info, full-res photo all flow LinkedIn → content script → App Group →
app). This plan covers what the **app process** does with that payload: match it
to an existing contact, show a per-field before/after diff with checkboxes, and
(later) save the chosen fields.

Companion docs: `docs/linkedin-safari-extension.md` (mechanism),
`plans/linkedin-safari-extension.md` (overall feature). The handoff currently
lands in `GuessWhoSceneDelegate.handleLinkedInHandoff` (logs only) — that's where
this flow hooks in.

## Matching rules (user-specified)

1. **Match by email first.** If any parsed `contactInfo.emails` matches a
   contact's email → that contact. Use
   `ContactsRepository.contactIDs(matchingEmail:)` (case-insensitive, returns
   ALL matches).
2. **Else match by display name.** `contactIDs(named: fullName)` /
   `lookupByDisplayName()`.
3. **Else → new-contact screen.** (Scope decision below.)

Multiple matches: take the single best and show it in the confirm dialog; if
there are several, note it and let the user proceed with the chosen one (full
disambiguation picker is a later refinement, not v1).

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

New files (App target):
- `LinkedInProfile.swift` — Codable model decoding the handoff JSON payload
  (mirrors the parsed shape: fullName, title, org, location, about,
  contactInfo{emails,websites,profileUrl}, photo{dataURL,contentType,byteLength}).
- `LinkedInMatcher.swift` — the email→name→none matching over `ContactsRepository`.
- `LinkedInConfirmView.swift` — SwiftUI diff dialog (left/right + per-row
  checkbox), hosted in a `UIHostingController` and presented from the scene
  delegate (same pattern the app uses for `ContactDetailView`/`EventDetailView`).
- `LinkedInDiff.swift` — builds `[DiffRow]` from existing `Contact` + parsed
  profile; each row carries field id, label, existing display, incoming display,
  changed flag, default-checked flag.

`GuessWhoSceneDelegate` decodes the payload and drives match → present, reaching
`ContactsRepository` via `GuessWhoAppDelegate.contactsRepository`.

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

1. `LinkedInProfile` Codable model + decode in the scene delegate (replace the
   log-only receiver). Verify the real payload decodes.
2. `LinkedInMatcher` (email → name → none) + unit-testable matching.
3. `LinkedInDiff` builder.
4. `LinkedInConfirmView` SwiftUI dialog (left/right + checkboxes, all ON,
   unchanged rows de-emphasized), presented on match.
5. **Save on Confirm** — apply checked rows across the three write paths:
   `saveContact` (name/title/org/emails/websites/LinkedIn-URL),
   `addNote` (bio; location sidecar field), and the **net-new contact-image
   write path** (photo). Build the photo write path as part of this step.
6. (Later) no-match create-new screen; `.blob` previous-photo; iOS target.

## Out of scope here

The contact-image WRITE path, the new-contact creation screen, the `.blob`
previous-photo work, and the iOS target — all later, per the overall plan.
