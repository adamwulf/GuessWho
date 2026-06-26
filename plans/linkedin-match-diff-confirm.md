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
| Name | `givenName` + `familyName` | `fullName` (split) | default checkbox OFF (rarely overwrite a name) |
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

## Scope decisions (need your confirmation)

1. **Does Confirm SAVE in this phase, or just log the chosen fields?**
   Recommendation: **build match + diff + dialog now; on Confirm, log the
   selected fields** (don't write yet). The real write — especially the **photo
   write path**, which is net-new package work (`CNContactStoreAdapter.apply()`
   deliberately skips image data) — is a focused follow-up. This keeps the
   match-and-confirm flow shippable and testable without the heaviest lift.
2. **No-match → new-contact screen:** placeholder for v1 (show the parsed
   preview + "no matching contact found", no create), with real creation as its
   own step? (The overall plan already deferred create-new to phase 2.)
3. **Default checkbox states:** all ON except Name (OFF — avoid clobbering a
   curated name). Photo ON. Confirm.
4. **Unchanged rows:** show de-emphasized vs. hide. Recommend de-emphasize.

## Build order

1. `LinkedInProfile` Codable model + decode in the scene delegate (replace the
   log-only receiver). Verify the real payload decodes.
2. `LinkedInMatcher` (email → name → none) + unit-testable matching.
3. `LinkedInDiff` builder.
4. `LinkedInConfirmView` SwiftUI dialog (left/right + checkboxes), presented on
   match; on Confirm, log the selected `[DiffRow]` (per scope #1).
5. (Follow-up) actual save: text fields via `saveContact`/`addNote`; **photo
   write path** (net-new package work); then no-match create-new.

## Out of scope here

The contact-image WRITE path, the new-contact creation screen, the `.blob`
previous-photo work, and the iOS target — all later, per the overall plan.
