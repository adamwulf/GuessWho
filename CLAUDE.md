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

## Building & testing

All commands are verified to build/pass on the current tree.

### App target (`xcodebuild`)

Build the app target from the `App/` directory. Use a local
`.build/DerivedData` so the package checkouts land alongside the build
products (easier dependency analysis).

- **Mac Catalyst:**
  ```sh
  xcodebuild -project App/GuessWho.xcodeproj -scheme GuessWho \
    -destination 'platform=macOS,variant=Mac Catalyst' \
    -derivedDataPath .build/DerivedData build
  ```
- **iPhone simulator** (pick an installed simulator name/OS from
  `xcrun simctl list devices available`):
  ```sh
  xcodebuild -project App/GuessWho.xcodeproj -scheme GuessWho \
    -destination 'platform=iOS Simulator,name=iPhone 17,OS=27.0' \
    -derivedDataPath .build/DerivedData build
  ```

### `Package.resolved` is ALWAYS committed, NEVER gitignored

**Both** `Package.resolved` lockfiles are always committed and are never
gitignored, so the exact built dependency set is recorded at every commit hash:

1. the **package-root** lockfile next to `Package.swift`
   (`./Package.resolved`), regenerated with `swift package resolve`; and
2. the **app workspace** lockfile at
   `App/GuessWho.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`.

There is **no** `Package.resolved` ignore rule anywhere in `.gitignore` — not
even a root-only `/Package.resolved`. We always commit both files so that we
know exactly what was built at each commit hash.

The app workspace lockfile is also load-bearing for the build: the app build
has automatic dependency resolution disabled, so a missing, stale, or untracked
`Package.resolved` breaks the build with:

> resolved file is required when automatic dependency resolution is disabled
> and should be placed at … `Package.resolved`

After adding, removing, or repinning any package dependency in `Package.swift`
or the Xcode project, re-resolve and commit **both** updated lockfiles. Don't
hand-edit a resolved file; change `Package.swift` / the project and re-resolve:

```sh
swift package resolve
git add Package.resolved

xcodebuild -project App/GuessWho.xcodeproj -scheme GuessWho \
  -resolvePackageDependencies -derivedDataPath .build/DerivedData
git add App/GuessWho.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
```

### Sync package (`swift`)

The `GuessWhoSync` package (storage + sync engine, no app shell) builds
and tests straight from the repo root with SwiftPM:

```sh
swift build          # compile GuessWhoSync + GuessWhoSyncTesting
swift test           # run Tests/GuessWhoSyncTests (XCTest + swift-testing)
```

Run a single test or suite with `swift test --filter <name>`. The same
targets are also exposed as the `GuessWhoSync` / `GuessWhoSyncTesting`
Xcode schemes.

## Identity: the GuessWho URL and unified contacts

A contact is identified **only** by its GuessWho ID — a UUID the package mints
and stores as a `guesswho://contact/<uuid>` URL on the contact. `Contact.localID`
(Apple's unified `CNContact.identifier`) is an internal, transient lookup token;
never persist, compare, or key GuessWho data on it. The package always works
with Apple-unified contacts, and reconciliation collapses any contact carrying
multiple GuessWho IDs onto one canonical ID.

**See [`docs/contact-identity.md`](docs/contact-identity.md)** for the full
treatment — GuessWho ID vs. `localID`, the unified-only fetch model, the four
reconciliation cases, and why callers must use the GuessWho ID. Read it before
touching identity or reconciliation.

Keep these concepts distinct: a Contacts **relationship** is a name-only
`CNContactRelation` resolved best-effort for UI; a sidecar **contact link** is a
durable `Link` between GuessWho-ID endpoints. Details and the package-caller
identity contract are in `docs/contact-identity.md`.

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
