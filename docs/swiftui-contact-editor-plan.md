# SwiftUI Contact Editor — Plan

## Goal

Replace `CNContactViewController` with a pure-SwiftUI editor for the
underlying `CNContact` fields, so the app compiles and behaves the same
on iOS and native macOS, and we can drop the `UIViewControllerRepresentable`
bridge entirely. Catalyst support is removed in the same change so the
app builds for two platforms only: iOS and native macOS.

## Non-goals

- Editing GuessWho-owned data (notes, links, events). Those already have
  their own SwiftUI editors and are out of scope.
- Editing contact image / thumbnail bytes. The existing adapter's
  `apply(_:to:)` deliberately leaves image data alone; the new editor
  inherits that.
- A unified create-new-contact flow. The existing CN-backed contact
  creation path (if any) is not what this work touches; we only replace
  the *edit* affordance, identified by `Edit` button → sheet from
  `ContactDetailView`.
- iCloud / sync behavior changes. Save goes through the existing
  `CNContactStoreAdapter.save(_:)` path, which the reconcile machinery
  already exercises.

## What we have today

- `Contact` (in `Sources/GuessWhoSync/`) — a Sendable struct that
  mirrors every CNContact field we currently read. Editing operates on
  this struct, not on `CNContact` directly.
- `CNContactStoreAdapter.save(_ contact: Contact)` — already round-trips
  the struct back to a `CNMutableContact` + `CNSaveRequest`. We reuse it.
- `ContactsRepository` — the cache the UI reads from. Already has
  `reload()`; we add a save-and-reload path.
- `SyncService.fetchCNContactForEditing(localID:)` — fetches a `CNContact`
  using `CNContactViewController.descriptorForRequiredKeys()`. We remove
  this method entirely (it's only called from the editor sheet) and
  load a `Contact` struct via the existing repository / adapter instead.
- `ContactEditView.swift` — the UIKit bridge being replaced. Deleted at
  the end of the work.

## Editor data model

The editor edits a `Contact` (the Sendable struct, not `CNContact`).
The form is initialized from a freshly-fetched copy, mutated as a
`@State`, and on Save the whole struct is passed to the adapter.

There is no diff-vs-original tracking in the save path itself — the
adapter's `apply(_:to:)` overwrites the mutable copy of the existing
CN record wholesale. (This matches the current reconcile-pass behavior.)
Image bytes are explicitly preserved by the adapter, so wholesale
overwrite of *editable* fields is safe.

The UI does need to detect "any change vs. original" to enable Save
and to drive the unsaved-changes confirmation on Cancel. That comparison
is a value-equality check on `Contact`, which is already `Equatable`.

## Row types — the core of the row-based design

Each editable CNContact field maps to one of a small set of row types.
The row owns its own validation/formatting; the form just lays them
out. Listed by the underlying `Contact` property:

| Row type            | Backing field(s)                                                | Edit affordance                                              |
| ------------------- | --------------------------------------------------------------- | ------------------------------------------------------------ |
| `NameFieldsRow`     | `namePrefix`, `givenName`, `middleName`, `familyName`,          | Multi-line group: prefix / first / middle / last / suffix /  |
|                     | `nameSuffix`, `nickname`                                        | nickname. No labels — collapses empty fields.                |
| `OrgFieldsRow`      | `organizationName`, `departmentName`, `jobTitle`                | Three plain text fields, only shown when contactType is      |
|                     |                                                                 | person OR organization (org gets organization first).        |
| `PhoneticNameRow`   | `phoneticGivenName`, `phoneticMiddleName`, `phoneticFamilyName` | Disclosed-by-default-collapsed section. Power-user only.     |
| `LabeledTextRow`    | `phoneNumbers`, `emailAddresses`, `urlAddresses`                | One row per entry: label picker + text field. Plus           |
|                     |                                                                 | "Add" affordance at the bottom of each section.              |
| `PostalAddressRow`  | `postalAddresses`                                               | Expanded multi-line editor: street / city / state / zip /    |
|                     |                                                                 | country. Label picker on header.                             |
| `DateRow`           | `birthday`, `dates`                                             | DatePicker for birthday. List of labeled dates for `dates`.  |
| `RelationRow`       | `contactRelations`                                              | Label picker + name text field. Picker uses standard         |
|                     |                                                                 | CN relation labels (mother, father, partner, …).             |
| `SocialProfileRow`  | `socialProfiles`                                                | Service picker + username + URL.                             |
| `IMRow`             | `instantMessageAddresses`                                       | Service picker + username.                                   |

Each row type lives in its own file under
`App/GuessWho/ContactEditor/Rows/`. Each is a `View` with `@Binding`
inputs to a slice of the `Contact` struct.

## Label picker

CN labels are mostly raw constants like `_$!<Home>!$_`. We render them
via `CNLabeledValue.localizedString(forLabel:)`. The picker:

- Offers the standard set per field type (home / work / mobile / …).
- Lets the user enter a custom label, stored verbatim. Custom labels
  round-trip through `CNLabeledValue` unchanged.
- Shows the localized form in the picker; stores the raw form in the
  `Contact` struct.

One shared `LabelPicker` view, parameterized by field type, is reused
across every labeled-value row.

## Form composition

`ContactEditView` (same file name, fully rewritten as SwiftUI):

```
NavigationStack {
    Form {
        Section { NameFieldsRow(...) }
        Section("Organization") { OrgFieldsRow(...) }   // if non-empty or contactType == .organization
        Section("Phone")        { phoneRows }
        Section("Email")        { emailRows }
        Section("URL")          { urlRows }
        Section("Address")      { postalRows }
        Section("Birthday")     { birthdayRow }
        Section("Dates")        { dateRows }
        Section("Related")      { relationRows }
        Section("Social")       { socialRows }
        Section("IM")           { imRows }
        Section("Phonetic")     { PhoneticNameRow(...) } // collapsed by default
        Section { deleteButton }
    }
    .toolbar { cancel, save }
}
```

Sections collapse to nothing when their list is empty AND the contact
isn't the kind that "owns" the section (e.g. an organization always
shows Organization). This avoids a wall of empty editors.

The current ContactEditView callback shape is preserved:
- Save → `onDone()`
- Cancel → no callback (sheet dismisses; nothing to refresh).
- Delete → `onDelete()`

So `ContactDetailView`'s `handleEditorDone` / `handleEditorDelete`
keep working unchanged.

## Save / cancel / delete

- **Save**: `try await repository.save(edited)`, which calls
  `contacts.save(edited)` on the adapter actor and then triggers a
  `repository.reload()`. The current detail-view post-edit dance
  (`performReconcile()` then `loadContact()` then `reload()`) is
  preserved because we still call `onDone` and the detail view runs
  the same handler.
- **Cancel**: dismiss without saving. If `edited != original`, present
  a confirmation dialog ("Discard changes?"). Standard pattern.
- **Delete**: `CNSaveRequest().delete(_:)` path. Add a
  `delete(localID:)` method to the adapter (it doesn't have one yet),
  fire `onDelete()` on success. Confirmation dialog before the actual
  call.

Errors from any of these surface as an `.alert` on the editor itself,
not a silent failure.

## Removing Catalyst, adding native macOS

Catalyst goes off; native macOS goes on. In the pbxproj this means:

- Drop the Mac Catalyst destination from the scheme / target.
- Add explicit `SUPPORTED_PLATFORMS = "iphoneos iphonesimulator macosx"`
  and set `MACOSX_DEPLOYMENT_TARGET` (matching `IPHONEOS_DEPLOYMENT_TARGET`).
- Ensure the existing macOS-incompatible bits are guarded or removed:
  - `.topBarTrailing` / other iOS-only toolbar placements → use
    `.primaryAction` (works on both).
  - `Settings.bundle` is iOS-only; either gate or keep it as-is (it
    just isn't built into the macOS product).
  - `UIScene` / `LSRequiresIPhoneOS` Info.plist keys harmlessly
    stripped by the Mac build (already observed in the recent build
    log).
- Anywhere else `#if canImport(UIKit)` was needed solely for the
  bridge: delete the guard once the bridge is gone.

A pre-flight grep for `UIKit`, `UIViewControllerRepresentable`,
`UIViewRepresentable`, and `topBarTrailing` confirms the scope is
small.

## File layout

```
App/GuessWho/ContactEditor/
    ContactEditView.swift               (rewritten, no UIKit)
    LabelPicker.swift
    LabelOptions.swift                  (per-field standard label sets)
    Rows/
        NameFieldsRow.swift
        OrgFieldsRow.swift
        PhoneticNameRow.swift
        LabeledTextRow.swift
        PostalAddressRow.swift
        BirthdayRow.swift
        DateRow.swift
        RelationRow.swift
        SocialProfileRow.swift
        IMRow.swift
```

The file name `ContactEditView.swift` is kept so the call site in
`ContactDetailView.swift` doesn't change, only its sheet body.

## Adapter additions

`CNContactStoreAdapter`:
- `func delete(localID: String) throws` — `CNSaveRequest.delete(_:)` on
  a fetched mutable copy. Mirrors `save(_:)`'s error semantics.

`SyncService` / repository:
- `func saveContact(_ contact: Contact) async throws` — wraps the adapter
  save and triggers a `reload`.
- `func deleteContact(localID: String) async throws` — adapter delete +
  reload.

`SyncService.fetchCNContactForEditing(localID:)` is **removed**. Its
two call sites (`presentEditor`, `EditingCNContact` struct) move to
fetching a `Contact` via the repository.

## Tests

- `ContactEditViewModelTests`:
  - Round-trip: load `Contact` → mutate → equality check against the
    save argument. (No CNContactStore in test.)
  - "Dirty?" detection: equality-based, including order-sensitive list
    fields (CN preserves order).
  - Label round-trip: standard label and custom label both survive a
    write/read cycle.
- `CNContactStoreAdapterTests`:
  - `delete(localID:)` against the test in-memory store.
- A new SwiftUI snapshot test is **not** introduced (we have none today;
  not the moment to start).

## Review-cycle integration points

- **After plan approval**: implement against this doc.
- **After implementation**: review-cycle skill (two reviewers, fix-and-
  iterate). Focus areas to call out for the reviewers:
  1. Catalyst-removal completeness (no lingering Catalyst-only API
     references, scheme cleanliness, Info.plist hygiene).
  2. Editor save correctness — especially label round-trip and the
     phonetic-section / org-section conditional display.
  3. Delete-flow safety: confirmation dialog, error surface, no
     orphaned sidecar data after delete.
  4. SwiftUI-only verification: build green on both iOS and native
     macOS destinations with zero `#if canImport(UIKit)` guards
     remaining in the editor area.

## Out-of-band considerations

- Mac contact-store authorization: `CNContactStore.requestAccess`
  already runs through the same code path on macOS; no new prompt
  plumbing required.
- The editor is the only UIKit holdover, but we should grep for
  other `representable` types and `UI*` calls once during
  implementation to be sure.
- After this lands, `docs/swiftui-contact-editor-plan.md` should be
  removed (or moved to an archive) — it's a planning doc, not a
  living one.

## Decided

1. **Label sets**: surface the common CN labels for every field type
   (anniversary, spouse, mother, father, partner, etc.) AND offer a
   "Custom…" option that lets the user type their own label, stored
   verbatim. Matches Contacts.app behavior.
2. **Picker rendering**: show the localized "Home / Work / Mobile" form
   in the picker UI, store the raw `_$!<Home>!$_` form in the `Contact`
   struct. Custom labels round-trip as-is.
3. **Delete affordance**: inside the editor sheet (matches the old
   `CNContactViewController` flow which had a Delete button at the
   bottom of the edit form), gated by a confirmation dialog.
