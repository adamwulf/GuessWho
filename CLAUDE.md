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
  EventKit+sidecar. The only divergence allowed is the source-of-truth icon
  used in list rows.

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
