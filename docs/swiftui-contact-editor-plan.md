# SwiftUI Contact Editor — Plan

## Goal

Replace `CNContactViewController` with a pure-SwiftUI editor for the
underlying `CNContact` fields, so the app compiles and behaves the same
on iOS, iPadOS, and native macOS, and we can drop the
`UIViewControllerRepresentable` bridge entirely. Mac Catalyst support
is removed in the same change so the app builds for two platform
families only: iOS family (iPhone + iPad) and native macOS.

## Non-goals

- Editing GuessWho-owned data (notes, links, events). Those already have
  their own SwiftUI editors and are out of scope.
- **Editing the contact photo (`imageData` / `thumbnailImageData`).**
  This is a deliberate, user-visible regression vs. the old
  `CNContactViewController` flow, which surfaced a tap-to-change photo
  affordance at the top of edit mode. We are accepting the regression
  in v1 to keep this change focused on field editing; the photo
  affordance moves to the project's deferred-features tracker for
  follow-up. The existing `apply(_:to:)` in the
  adapter already skips image bytes, so saves preserve whatever bytes
  are already on the contact.
- **In-line name suggestions** (Apple's edit-mode "Smith" → "Smith
  family" banners). Not reproducible in SwiftUI without private API.
  Accepted v1 regression; tracked alongside photos.
- **Creating a new contact from scratch.** Confirmed by grep: the only
  entry point today is `ContactDetailView.presentEditor()` and it
  always starts from an existing `CNContact`. New-contact creation is
  out of scope.
- **Changing `contactType` (person ↔ organization)** after creation.
  Apple's Contacts.app supports it; we don't, in v1.
- **Editing `nonGregorianBirthday`.** It rides through unchanged
  (preserved per §"Data preservation"). v1 has no UI for it.
- Editing contact image / thumbnail bytes (restated; covered above).
- iCloud / sync behavior changes. Save goes through the existing
  `CNContactStoreAdapter.save(_:)` path, which the reconcile machinery
  already exercises.

## What we have today

- `Contact` (`Sources/GuessWhoSync/Contact.swift`) — a Sendable struct
  that mirrors every CNContact field we currently read.
- `CNContactStoreAdapter.save(_ contact: Contact)` (actor-isolated) —
  already round-trips the struct back to a `CNMutableContact` +
  `CNSaveRequest`. We reuse it. Image bytes are deliberately preserved
  by `apply(_:to:)` so wholesale overwrite is safe (`CNContactStoreAdapter.swift:248-252`).
- `ContactsRepository` — the cache the UI reads from; has `reload()`.
  The repository does NOT hold the adapter directly — `SyncService`
  owns it. So the save path is editor → `SyncService.saveContact(_:)` →
  `contacts.save(_:)` on the adapter actor → `await repository.reload()`
  back on the main actor. Mirrors the existing `fetchAll` pattern
  (`SyncService.swift:448-456`).
- `SyncService.fetchCNContactForEditing(localID:)` — the old UIKit
  bridge fetch. Removed entirely with this change, along with its
  unconditional `import ContactsUI` at the top of `SyncService.swift`
  (line 3). `ContactsUI` does not build on native macOS; leaving the
  import in is a hard compile failure on the new destination.
- `ContactEditView.swift` — the UIKit bridge being replaced. Rewritten
  in place as SwiftUI (same filename so the call site in
  `ContactDetailView.swift` stays put).

## Data preservation — carry-through-without-UI fields

The editor's row UI does NOT cover every field on `Contact`. The
adapter's `apply(_:to:)` overwrites editable fields wholesale on
save (this is by design — it matches the reconciler's behavior).
**Therefore: any field not surfaced by a row must still be carried
through unmodified, or wholesale save will silently clear it.**

The contract:
- The editor loads a `Contact` from the freshly-fetched original.
- That `Contact` lives entirely in a single `@State edited: Contact`.
- Rows bind to slices of `edited` (`$edited.givenName`,
  `$edited.phoneNumbers`, etc.).
- Fields with no row binding are never re-assigned — they ride through
  in `edited` from load to save.

Fields with NO row binding in v1, which MUST ride through:

| Field                                | Lives on                              | Why no row                                  |
| ------------------------------------ | ------------------------------------- | ------------------------------------------- |
| `previousFamilyName`                 | `Contact`                             | Rare; not user-edited                       |
| `phoneticOrganizationName`           | `Contact`                             | Rare; not user-edited                       |
| `nonGregorianBirthday`               | `Contact`                             | Niche calendars; deferred                   |
| `socialProfiles[].userIdentifier`    | `SocialProfile`                       | Service-internal stable ID                  |
| `postalAddresses[].subLocality`      | `PostalAddress`                       | CJK / UK addressing; not in v1 row layout   |
| `postalAddresses[].subAdministrativeArea` | `PostalAddress`                  | Same                                        |
| `postalAddresses[].isoCountryCode`   | `PostalAddress`                       | Drives locale-correct formatter rendering   |
| All `urlAddresses` entries with `value.hasPrefix(SidecarKey.guessWhoContactURLPrefix)` | `Contact` | **Identity URL — sidecar binding** |
| `CNContact.note` | CNContact only; not on `Contact` | Reading `note` requires the `com.apple.developer.contacts.notes` entitlement. The adapter's key list (`CNContactStoreAdapter.swift:54`) deliberately omits `CNContactNoteKey`, so the field isn't fetched and `apply(_:to:)` never sets `mutable.note`. Existing notes on the CN record survive a wholesale-overwrite save because we re-fetch and `mutableCopy()` the original (`CNContactStoreAdapter.swift:85-88`) before applying — so any field `apply` doesn't touch is preserved by the CN copy. |

The GuessWho identity URL is the most critical case. Deleting it
severs the contact ↔ sidecar binding (notes, links, events all
become orphans). The URL editor section MUST hide it AND re-merge
it back into the saved `urlAddresses` array before write.

**Predicate (single source of truth):** the editor partitions
`urlAddresses` by `value.hasPrefix(SidecarKey.guessWhoContactURLPrefix)`.
The matching bucket is carried through verbatim and never shown; the
non-matching bucket is the "user URLs" the editor binds to.

This is the **broad** prefix-match, NOT the parse-OK filter at
`ContactDetailView.swift:278` (`SidecarKey.parseGuessWhoContactURL(...) == nil`).
The reviewer-flagged divergence is intentional: the detail view's
filter is correct for *display* (don't tease users with malformed
guesswho URLs they can't usefully tap), but the editor must err on
the side of hiding *any* `guesswho://` entry — well-formed or
malformed — so a user can never edit/delete one. Reconcile cleans
up malformed entries on its next pass (`GuessWhoSync.swift:538-539,
567-568`); the editor's job is to not let them become user-editable
in the meantime.

**Merge order (preserves user ordering):** iterate the loaded
`original.urlAddresses` in array order. For each slot:
- If it matches the GuessWho prefix → carry the original entry to
  the saved list (skip the visible-bucket cursor).
- Otherwise → consume the next entry from the edited visible bucket
  and write it to the saved list.

After all original slots are consumed, append any *new* entries the
user added in the visible bucket (these have no original index).
This preserves the user's manually-imposed URL ordering across an
edit; the GuessWho URL stays at its original index.

Tests in §"Tests" exercise every carry-through field explicitly,
including both a well-formed and a malformed `guesswho://` URL.

## Editor data model

The editor edits a `Contact` (the Sendable struct, not `CNContact`).
The form is initialized from a freshly-fetched copy, mutated as a
`@State`, and on Save the whole struct is passed to the adapter via
`SyncService.saveContact(_:)`.

### Dirty-state tracking

The plan uses an explicit `@State isDirty: Bool` flag flipped on any
user input, NOT a deep `Equatable` comparison against the original.
Reasons:
- The adapter normalizes labels (`label.isEmpty ? nil : label`), so a
  load → save round-trip can flip equality in subtle non-user-visible
  ways.
- Row-reorder drag gestures shouldn't necessarily count as "dirty";
  explicit flag lets the row author decide.

`isDirty` drives:
- Save button enable/disable.
- Cancel-with-unsaved-changes confirmation dialog.

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
| `PhoneticNameRow`   | `phoneticGivenName`, `phoneticMiddleName`, `phoneticFamilyName` | `DisclosureGroup`, collapsed by default. Power-user only.    |
| `LabeledTextRow`    | `phoneNumbers`, `emailAddresses`, `urlAddresses`                | One row per entry: label picker + text field. Plus           |
|                     |                                                                 | "Add" affordance always visible at the bottom of each        |
|                     |                                                                 | section, even when the list is empty.                        |
| `PostalAddressRow`  | `postalAddresses` (street, city, state, postal code, country)   | Expanded multi-line editor with label picker on header.      |
|                     |                                                                 | `subLocality`, `subAdministrativeArea`, `isoCountryCode`     |
|                     |                                                                 | are carry-through (see §"Data preservation").                |
| `BirthdayRow`       | `birthday` (DateComponents)                                     | "Add Birthday" button when nil; DatePicker + remove when     |
|                     |                                                                 | present. See §"Birthday/DateComponents handling".            |
| `DateRow`           | `dates` (LabeledDate list)                                      | Label picker + DatePicker per entry; "Add Date" affordance.  |
| `RelationRow`       | `contactRelations`                                              | Label picker + name text field. Picker uses standard         |
|                     |                                                                 | CN relation labels (mother, father, partner, …) plus         |
|                     |                                                                 | "Custom…" sheet.                                             |
| `SocialProfileRow`  | `socialProfiles` (service, username, url)                       | Service picker + username + URL. `userIdentifier` is         |
|                     |                                                                 | carry-through.                                               |
| `IMRow`             | `instantMessageAddresses`                                       | Service picker + username.                                   |

`BirthdayRow` and `DateRow` are separate files because birthday is a
single optional value and `dates` is a labeled list — the UI shapes
differ enough that combining them would be more code, not less.

Each row type lives in its own file (see §"File layout" for the
rationale on a subdirectory). Each is a `View` with `@Binding` inputs
to a slice of `edited: Contact` plus a `@Binding<Bool>` to the parent's
`isDirty` flag.

### Birthday / DateComponents handling

`Contact.birthday` is `DateComponents?` — explicitly so a "no year"
birthday survives. SwiftUI's `DatePicker` needs a `Date`. The row:

- When loading: convert `DateComponents` to `Date` via
  `Calendar.current.date(from:)`. If `year` is missing in components,
  substitute a sentinel year (e.g. 2000) for the picker; remember that
  the original was no-year via a `@State hasYear: Bool` flag.
- When writing: reconstruct `DateComponents`. If `hasYear == false`,
  set only `month` and `day` on the result, dropping the picker's
  sentinel year.
- UI surfaces a "Include year" toggle so the user can opt in/out;
  matches Contacts.app's behavior.

### Section visibility — Add affordance is always present

The "section collapses when empty" rule from earlier drafts created a
contradiction: a contact with zero phone numbers would have no UI for
adding the first. Resolved:

- The labeled-list sections (Phone, Email, URL, Address, Date,
  Related, Social, IM) **always render a section header and an Add
  affordance**, even when the list is empty.
- Singleton sections (Name, Org, Phonetic, Birthday) render
  conditionally:
  - Name: always shown.
  - Org: **always shown in edit mode**, regardless of contactType
    or whether the fields are populated. Matches Contacts.app —
    its edit view always exposes Company / Department / Job Title
    even for a fresh person contact. (The earlier "shown when
    contactType == .organization OR non-empty" rule created a
    deadlock: a person contact with empty org fields had no UI to
    add the first one.)
  - Phonetic: a `DisclosureGroup` with label "Phonetic Name",
    collapsed by default. Always available.
  - Birthday: always shown; row internally toggles between "Add
    Birthday" button and editor (with "Include year" toggle when
    editor is open — see §"Birthday/DateComponents handling").

### Validation policy

Match Contacts.app: **the editor does NOT block save on field-content
validation.** Phone numbers, URLs, emails are saved as the user typed
them. Adapter / CN may reject save at the system level (e.g.
`invalidFieldValue`); those surface via the alert pipeline below.

## Label picker

CN labels are mostly raw constants like `_$!<Home>!$_`. We render via
`CNLabeledValue.localizedString(forLabel:)`. The picker:

- Offers the standard set per field type (home / work / mobile / …)
  — including the less-common labels like `anniversary`, `spouse`,
  `partner` for dates/relations, matching Contacts.app's full list.
- Always offers a "Custom…" entry that opens a small text-input sheet
  for a user-typed label, stored verbatim. Round-trips unchanged.
- Picker UI shows the **localized form** ("Mobile", "Home"); the
  `Contact` struct stores the **raw form** (`_$!<Mobile>!$_`).

One shared `LabelPicker` view, parameterized by the field type's
allowed label set, is reused across every labeled-value row.

## Form composition

`ContactEditView` (same file name, fully rewritten as SwiftUI):

```
NavigationStack {
    Form {
        Section { NameFieldsRow(...) }
        if orgVisible { Section("Organization") { OrgFieldsRow(...) } }
        Section("Phone")    { phoneRows;    AddRowButton(...) }
        Section("Email")    { emailRows;    AddRowButton(...) }
        Section("URL")      { urlRows;      AddRowButton(...) }   // filters out guesswho://
        Section("Address")  { postalRows;   AddRowButton(...) }
        Section("Birthday") { BirthdayRow(...) }
        Section("Dates")    { dateRows;     AddRowButton(...) }
        Section("Related")  { relationRows; AddRowButton(...) }
        Section("Social")   { socialRows;   AddRowButton(...) }
        Section("IM")       { imRows;       AddRowButton(...) }
        Section { PhoneticNameRow(...) }    // row is a self-collapsing DisclosureGroup (label: "Phonetic Name")
        Section { deleteButton }
    }
    .formStyle(.grouped)                      // see §"macOS specifics"
    .toolbar { cancel, save }
}
```

`.formStyle(.grouped)` is set so macOS doesn't render this as a
settings-style two-column pane.

The current ContactEditView callback shape is preserved:
- Save → `onDone()`
- Cancel → no callback (sheet dismisses; nothing to refresh).
- Delete → `onDelete()`

So `ContactDetailView`'s `handleEditorDone` / `handleEditorDelete`
keep working unchanged.

## Save / cancel / delete

- **Save**: `try await service.saveContact(edited)`. That method (new
  on `SyncService`) awaits the adapter actor's `contacts.save(edited)`
  and then `await repository.reload()` back on the main actor,
  mirroring the existing `fetchAll` pattern (`SyncService.swift:448-456`).
  On success, fires `onDone()`. The post-edit dance owned by
  `ContactDetailView.handleEditorDone` (`performReconcile()` →
  `loadContact()` → `repository.reload()`) is preserved verbatim
  because we still call `onDone` and the detail view runs the same
  handler.
- **Cancel**: dismiss without saving. If `isDirty == true`, present a
  `confirmationDialog` ("Discard changes?"). Standard pattern.
- **Delete**: confirmation `confirmationDialog` first. On confirm,
  `try await service.deleteContact(localID:)` (new) which calls
  `contacts.delete(localID:)` on the adapter and then
  `repository.reload()`. Fire `onDelete()` on success. The detail-view
  handler then pops if the contact is actually gone (existing logic at
  `ContactDetailView.swift:205-207`).

### Sidecar tombstone on delete

Deleting the CN contact leaves the sidecar (notes, links, events)
orphaned under the now-gone UUID. v1 policy: **leave sidecars
orphaned, do not actively delete them.** Reasons:
- iCloud sync is eventually-consistent; another device may still hold
  the contact for a brief window after delete on this device.
- Reconcile already handles orphans gracefully (a sidecar with no
  matching CN UUID is dormant, not broken).
- An explicit "delete sidecar by contact" API does not exist today and
  designing it carefully (especially across iCloud) is its own
  workstream.

This is documented as a known v1 behavior; the deferred-features
tracker should pick up "sidecar GC on contact delete" for follow-up.

### Save error contract

Errors surface as an `.alert` on the editor sheet itself. **On
alert-dismiss the editor stays open with the user's `edited` state
intact** so they can fix the field and retry Save. The editor never
auto-dismisses on a save error.

Text matched to the error category:

- `CNError.authorizationDenied` / permission revoked mid-edit:
  "Couldn't save — Contacts access was revoked. Open Settings to
  re-enable."
  - On iOS, the alert offers a secondary "Open Settings" button that
    calls `UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)`.
    Wrap this button in `#if !os(macOS)`.
  - On native macOS, no equivalent deep-link; alert is text-only.
    User navigates to System Settings themselves.
- `CNError.invalidFieldValue` / validation: "Couldn't save — one of
  the fields was rejected by the system: `<localizedDescription>`."
- `CNError.recordDoesNotExist` (race: another client deleted it):
  "This contact has been deleted on another device. Close the editor
  to refresh."
- Catch-all: `error.localizedDescription`.

Codify the category mapping in `ContactEditModel.saveErrorCategory(_:)`
so test coverage stays straightforward.

### Delete error contract

Same alert pipeline, with two important differences:

- `CNError.recordDoesNotExist` from delete is treated as **success**,
  not error. The contact is already gone — that's what the user
  asked for. The editor fires `onDelete()` and the detail view
  proceeds to pop normally.
- All other CN errors map to the same categories as save above
  (authorizationDenied, invalidFieldValue, catch-all) but with
  delete-specific wording ("Couldn't delete — …").

On a delete error other than `recordDoesNotExist`, the editor stays
open. The user's edited state is preserved (delete didn't run; save
is still available).

## Removing Catalyst, adding native macOS

Catalyst goes off; native macOS is the macOS path.

The project's build settings live in `App/Config/*.xcconfig`, NOT in
`project.pbxproj`'s `XCBuildConfiguration` blocks (those are mostly
empty and inherit from `baseConfigurationReference`). Concrete edits:

- `App/Config/GuessWho-Shared.xcconfig`:
  - Line 22 already has `SUPPORTED_PLATFORMS = iphoneos iphonesimulator macosx` — leave as-is.
  - Line 26 `SUPPORTS_MACCATALYST = YES` → **delete** (or set to `NO`).
  - Line 27 `SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD = NO` → leave as-is.
  - Line 28 `DERIVE_MACCATALYST_PRODUCT_BUNDLE_IDENTIFIER = NO` → delete (Catalyst-specific knob, no-op once Catalyst is off, but tidy).
- `App/Config/Project-Shared.xcconfig`:
  - Line 65 `SUPPORTED_PLATFORMS = iphoneos iphonesimulator` → grow to `iphoneos iphonesimulator macosx` so the project-level matches the target-level (currently only the target adds macosx).
- `GuessWho.xcodeproj/xcshareddata/xcschemes/*.xcscheme`: remove the
  Mac Catalyst destination entry from the scheme. The Xcode "Supported
  Destinations" UI writes this here, not in the pbxproj.

**Deployment-target floor:** currently `IPHONEOS_DEPLOYMENT_TARGET = 17.0`
and `MACOSX_DEPLOYMENT_TARGET = 14.0` (in both `Project-Shared.xcconfig`
and `GuessWho-Shared.xcconfig`). **Do not bump them as part of this
change** — bumping is its own scope question (`.formStyle(.grouped)`,
`.confirmationDialog`, and the other macOS specifics this plan uses
are all available on 14.0+, so the existing floor is sufficient).
The `@FocusState`-on-macOS Tab navigation specifics in §"SwiftUI on macOS"
may need `@available(macOS 14.0, *)` annotations on any newer API the
implementer reaches for; check at implementation time.

In code:

- **`SyncService.swift` line 3**: remove the unconditional
  `import ContactsUI`. It exists only for the deleted
  `fetchCNContactForEditing` method's
  `CNContactViewController.descriptorForRequiredKeys()` call.
  Replace with the explicit key list the adapter already uses (or
  delete the method outright and route through the adapter).
- **`RootView.swift:99-109`**: the existing Settings-tab guard is
  `#if targetEnvironment(macCatalyst)` because Catalyst ignores
  `Settings.bundle`. **Native macOS ALSO ignores `Settings.bundle`.**
  Broaden the guard to
  `#if targetEnvironment(macCatalyst) || os(macOS)` (or equivalently
  `#if !os(iOS)`) so Debug Mode remains reachable on macOS.
- **`ContactDetailView.swift`**: the `#if canImport(UIKit)` guards
  added in commit 78d690e around `.sheet(item:)` and the Edit toolbar
  item are **removed** — once `ContactEditView` is pure SwiftUI it
  builds on both platforms.
- **`.topBarTrailing`** in the toolbar branch is iOS-only. Switch to
  `.primaryAction` (works on both, matches existing convention at
  `EventDetailView.swift:63`).

In `Info.plist`:

- **`LSRequiresIPhoneOS`** (line 27-28): explicitly remove. The Mac
  build's strip behavior we observed (build log: "removing entry for
  LSRequiresIPhoneOS - not supported on macOS") works, but submission
  /signing hygiene prefers it absent.
- **`UIApplicationSceneManifest`** (line 33-39): leave as-is. It does
  no harm on the macOS build and removing it would force a parallel
  iOS scene-config rework. Worth a one-line code comment marking it
  iOS-only.

Pre-flight grep before declaring the move done — patterns split so
the implementer knows what each one catches:

```
# UIKit / Catalyst symbols that don't exist on native macOS:
grep -rn "ContactsUI\|UIViewControllerRepresentable\|UIViewRepresentable\|topBarTrailing\|UIApplication\.shared\|UIWindow\|UISceneSession\|UISceneConfiguration\|presentationDetents" --include="*.swift" App/GuessWho Sources

# Catalyst-only conditionals (compile and availability):
grep -rn "targetEnvironment(macCatalyst)\|macCatalyst " --include="*.swift" App/GuessWho Sources
```

The second grep catches both `#if targetEnvironment(macCatalyst)`
*and* the `macCatalyst 18.0` availability literal at
`RootView.swift:115` (`if #available(iOS 18.0, macCatalyst 18.0, macOS 15.0, *)`)
that the first round of greps missed. Delete the literal — with
Catalyst gone, `macCatalyst 18.0` is dead.

Every hit must be either deleted, re-routed, or carry a one-line
comment justifying why it's still there. The implementer must NOT
introduce new `#if canImport(UIKit)` guards inside
`App/GuessWho/ContactEditor/`; any UIKit affordance reached for in
the editor area (e.g. an `openSettingsURLString` deep-link on iOS)
needs the guard *and* an inline comment explaining the divergence.

## SwiftUI on macOS — specifics this plan commits to

These are the cross-platform behaviors the implementer must hit
explicitly. Each is a known divergence between iOS and native macOS
that defaults badly on one side.

- **`.formStyle(.grouped)`** on the top-level `Form` so macOS doesn't
  render two-column settings-style. Already in the form sketch above.
- **Sheet sizing**: SwiftUI sheets on macOS open at intrinsic size.
  Set `.frame(minWidth: 480, idealWidth: 560, minHeight: 600, idealHeight: 720)`
  on the sheet's root view inside `#if os(macOS)` so it opens at a
  workable size and is user-resizable. On iOS, use
  `.presentationDetents([.large])` inside `#if !os(macOS)`. `Form`
  already provides internal scrolling on both platforms; verify on
  macOS that it does inside the sheet, since intrinsic-size sheets
  can otherwise grow unbounded.
- **`@FocusState` tab navigation**: name and address rows have
  multiple text fields. Wire a `@FocusState` enum per multi-field row
  and use `.focused($focus, equals: .field)` plus `.onSubmit { focus = next }`
  so Tab / Shift-Tab advances through fields. Tab orders:
  - `NameFieldsRow`: prefix → first → middle → last → suffix → nickname.
  - `PostalAddressRow`: street → city → state → postal code → country.
    (Carry-through sub-fields skipped.)
  - `OrgFieldsRow`: organizationName → departmentName → jobTitle.
  - `PhoneticNameRow`: phoneticGivenName → phoneticMiddleName → phoneticFamilyName.
- **`DatePicker` no-year case**: handled in §"Birthday/DateComponents
  handling". Render "Include year" as `Toggle("Include year", isOn: $hasYear)`
  immediately below the DatePicker. Apply the same `hasYear` semantics
  to `DateRow` (anniversary, etc.) so the behavior is consistent.
- **`confirmationDialog`** for unsaved-changes and delete: rendered as
  a modal alert sheet on macOS and a bottom action sheet on iOS. Both
  acceptable; intentional cross-platform idiom. Button copy:
  - Cancel-with-unsaved-changes: `Button("Discard Changes", role: .destructive) { dismiss() }`
    + `Button("Keep Editing", role: .cancel) {}`.
  - Delete-contact: `Button("Delete Contact", role: .destructive) { performDelete() }`
    + `Button("Cancel", role: .cancel) {}`.
- **Delete `role: .destructive`** styling differs visually between
  platforms. Verify manually on both; no code-level workaround.

## File layout

```
Sources/GuessWhoSync/
    ContactEditModel.swift              (pure model; testable without SwiftUI)

App/GuessWho/ContactEditor/
    ContactEditView.swift               (rewritten, no UIKit; the entry View)
    LabelPicker.swift
    LabelOptions.swift                  (per-field standard label sets — enumerates
                                         CNLabel* constants per field type, e.g.
                                         phone: [CNLabelPhoneNumberMobile,
                                         CNLabelPhoneNumberMain, CNLabelHome,
                                         CNLabelWork, CNLabelOther]; dates:
                                         [CNLabelDateAnniversary, ...]; relations:
                                         [CNLabelContactRelationFather, ...])
    Rows/
        NameFieldsRow.swift
        OrgFieldsRow.swift
        PhoneticNameRow.swift
        LabeledTextRow.swift            (phone, email, url)
        PostalAddressRow.swift
        BirthdayRow.swift
        DateRow.swift
        RelationRow.swift
        SocialProfileRow.swift
        IMRow.swift
```

`ContactEditModel` lives in `GuessWhoSync` (not the app target) so
it's testable from `GuessWhoSyncTests` without an app-target test
bundle. It depends only on `Contact` and standard library types — no
SwiftUI imports, no CN types.

**Why a subdirectory and not co-located private structs.** The
existing convention (`EventEditSheet` co-located inside
`EventDetailView.swift:441`; `AddLinkSheet` inside
`ConnectionsSection.swift:151`) holds when the sub-sheet has one or
two private subviews. Here we have ten distinct row types, each with
its own label set, validation, and a non-trivial layout. Co-locating
all of them produces a single ~1000-line file that's painful to
navigate. The subdirectory is justified by:

- Per-row unit tests in §"Tests" target row-level data binding in
  isolation; that's easier when each is its own type at its own path.
- New row additions (e.g. a future Photo row) drop in without touching
  the parent file.

The file name `ContactEditView.swift` is kept so the call site in
`ContactDetailView.swift` doesn't change, only its sheet body.

## Adapter additions

`Sources/GuessWhoSync/CNContactStoreAdapter.swift`:
- `public func delete(localID: String) throws`. Implementation:

  ```swift
  public func delete(localID: String) throws {
      let cn: CNContact
      do {
          cn = try store.unifiedContact(
              withIdentifier: localID,
              keysToFetch: [CNContactIdentifierKey as CNKeyDescriptor]
          )
      } catch let error as CNError where error.code == .recordDoesNotExist {
          throw ContactStoreError.contactNotFound(localID: localID)
      }
      // mutableCopy() on a CNContact always returns a CNMutableContact;
      // the cast can't actually fail. Force-cast keeps the intent crisp.
      let mutable = cn.mutableCopy() as! CNMutableContact
      let req = CNSaveRequest()
      req.delete(mutable)
      try store.execute(req)
  }
  ```

  The `do/catch` re-throws `CNError.recordDoesNotExist` as
  `ContactStoreError.contactNotFound`, mirroring the existing pattern
  in `loadImageData` (`CNContactStoreAdapter.swift:97-104`).

`Sources/GuessWhoSync/ContactStoreProtocol.swift`:
- Add `func delete(localID: String) throws` to the protocol so the
  in-memory test fake can implement it. Without this, the adapter
  test described in §"Tests" cannot be written.

`App/GuessWho/Support/SyncService.swift`:

```swift
func saveContact(_ contact: Contact) async throws {
    try await contactsAdapter.save(contact)
    await repository.reload()
}

func deleteContact(localID: String) async throws {
    try await contactsAdapter.delete(localID: localID)
    await repository.reload()
}
```

- **Remove** `fetchCNContactForEditing(localID:)` and the
  `import ContactsUI` at line 3.
- The inner `await repository.reload()` in `saveContact` is
  intentionally redundant with `ContactDetailView.handleEditorDone`'s
  trailing `repository.reload()` (`ContactDetailView.swift:194`). The
  cost is one extra cache-rebuild per save; the benefit is that
  `saveContact` is correct on its own for any future caller, not
  only the editor. Accepted redundancy.

## Tests

There is no `Tests/GuessWhoTests/` app-target test bundle today;
creating one is its own scope. So this plan keeps the test sites
inside the existing `Tests/GuessWhoSyncTests/` and the new editor
model logic is **extracted into the `GuessWhoSync` module as a pure
struct/class** (`ContactEditModel`) so it can be exercised without
a SwiftUI / view-bundle dependency.

`Sources/GuessWhoSync/ContactEditModel.swift` (new): owns the
`edited: Contact`, the `original: Contact`, the `isDirty` flag, the
URL partition + re-merge logic, the birthday `hasYear` conversion,
and the save-error category mapping. The SwiftUI views in
`App/GuessWho/ContactEditor/` bind to this model. No CN types in
the model — it operates on `Contact` only.

`Tests/GuessWhoSyncTests/`:

- **`CNContactStoreAdapterRoundTripTests`** — using an in-memory store
  fake, assert that for a `Contact` with every field populated
  (including `previousFamilyName`, `phoneticOrganizationName`,
  `nonGregorianBirthday`, `postalAddresses[].subLocality`,
  `socialProfiles[].userIdentifier`, and a `guesswho://` URL in
  `urlAddresses`), `load → mutate one visible field → save → load`
  preserves every other field unchanged. This is the **floor**
  guarantee — the adapter itself doesn't lose fields.
- **`CNContactStoreAdapterDeleteTests`** — `delete(localID:)` removes
  the contact; subsequent `fetch(localID:)` returns nil; deleting a
  missing ID throws `contactNotFound`.
- **`ContactEditModelTests`** (new) — exercises the editor's
  data-binding logic, NOT just the adapter floor. **This is the
  test that protects the sidecar binding.**
  - Dirty-flag transitions on mutation; cancel-confirmation only when
    dirty.
  - Label round-trip: standard `_$!<Home>!$_` label survives unchanged
    when only the value is edited (not lowercased, not localized).
  - URL section: editing a non-GuessWho URL re-merges with the
    GuessWho identity URL on save; the identity URL is never visible
    to the binding.
  - URL section: a malformed `guesswho://contact/garbage` URL is also
    hidden from the binding and carried through verbatim.
  - URL ordering: a contact with `[user1, guesswho, user2]` edited to
    rename `user1` saves as `[user1', guesswho, user2]` (positions
    preserved, not re-shuffled).
  - Birthday no-year case: a `DateComponents` with only month/day
    survives load → no-op-save round-trip with year still absent.

Manual verification (drive via the `/verify` skill before declaring
the work merged):

- iOS and native macOS destinations both build green. The
  `App/GuessWho/ContactEditor/` directory has **no `#if canImport(UIKit)`
  guards EXCEPT** those required for iOS-only affordances explicitly
  named in this plan — currently just the iOS "Open Settings" deep-link
  button in the save-error alert (see §"Save error contract"). Each
  such guard carries a one-line inline comment naming the affordance
  and the platform divergence.
- Open an existing contact → Edit → change name → Save → reopen,
  confirm change persisted.
- Open contact with a photo set → Edit → Save → reopen, confirm photo
  still present.
- Edit URL section on a contact with a `guesswho://` URL → save → on
  next reconcile pass, sidecar binding is intact (notes still
  accessible).
- Cancel with unsaved changes → confirmation dialog appears.
- Delete from inside editor → confirmation dialog → on confirm,
  detail view pops, list reload removes the row.
- Debug Mode tab is reachable on macOS via the in-app Settings tab.

SwiftUI snapshot tests / XCUITest are out of scope for v1 (no
existing harness in the project to extend); manual `/verify`
substitutes.

## Review-cycle integration points

- **After plan approval** (this revision): implement against this doc.
- **After implementation**: review-cycle skill (two reviewers, fix-
  and-iterate). Focus areas to call out for the reviewers:
  1. Catalyst-removal completeness: no `ContactsUI` import remains, no
     `targetEnvironment(macCatalyst)` guard remains without an
     `os(macOS)` companion, both iOS and native macOS destinations
     build green, scheme/Info.plist hygiene.
  2. Editor save correctness — every §"Data preservation" carry-
     through field survives a roundtrip including the GuessWho URL.
  3. Label round-trip — raw form preserved, custom-label round-trip.
  4. Delete-flow safety — confirmation dialog, error surface, detail
     view pops only after actual deletion confirmed by reload.
  5. macOS rendering — `.formStyle(.grouped)` set, sheet sized,
     FocusState wired for tab navigation, DatePicker no-year case
     visually correct.
  6. Debug Mode reachable on macOS.

## Out-of-band considerations

- Mac contact-store authorization: `CNContactStore.requestAccess`
  already runs through the same code path on macOS; no new prompt
  plumbing required.
- After this lands, move this doc to `docs/archive/` (don't delete)
  so the next time this area is touched, the context — what we
  considered, what we deferred, why — is still recoverable.

## Decided

1. **Label sets**: surface the common CN labels for every field type
   (anniversary, spouse, mother, father, partner, etc.) AND offer a
   "Custom…" option that lets the user type their own label, stored
   verbatim. Matches Contacts.app behavior. *(This decision drives
   the §"Label picker" allowed-set wiring.)*
2. **Picker rendering**: show the localized "Home / Work / Mobile"
   form in the picker UI, store the raw `_$!<Home>!$_` form in the
   `Contact` struct. Custom labels round-trip as-is.
3. **Delete affordance**: inside the editor sheet (matches the old
   `CNContactViewController` flow), gated by a confirmation dialog.
4. **Section visibility**: labeled-list sections always render header +
   Add affordance even when empty. Singleton sections per §"Section
   visibility — Add affordance is always present".
5. **Validation policy**: match Contacts.app — save does not
   block on field content; the system surfaces validation rejections
   via the alert pipeline.
6. **Dirty-state tracking**: explicit `@State isDirty: Bool` flag
   flipped by row authors on user input. NOT a deep `Equatable`
   compare against the original (adapter normalization makes equality
   fragile, per §"Editor data model").
7. **Photo / name-suggestion regressions**: explicitly accepted as v1
   regressions; tracked in deferred-features for follow-up.
8. **Sidecar-on-delete**: v1 policy is leave orphaned; explicit
   sidecar GC is deferred work. Reconcile mints fresh UUIDs (UUID
   v4), so a deleted contact's UUID will never collide with a future
   re-stamped contact — orphan sidecars are inert, not a
   re-attachment hazard. A user who deletes a contact and later
   re-adds one with the same name does NOT see the old notes/links
   return; the binding is by UUID, not name.
9. **URL-filter predicate**: editor partitions `urlAddresses` by
   `value.hasPrefix(SidecarKey.guessWhoContactURLPrefix)`. Broad
   prefix-match — well-formed and malformed `guesswho://` URLs are
   both hidden from the editor and carried through verbatim. NOT the
   detail-view's narrower parse-OK filter (which is correct for
   display but wrong for the editor's hide-and-carry-through job).
10. **Org-section visibility**: always shown in edit mode (matches
    Contacts.app), regardless of `contactType` or whether the fields
    are populated. Resolves the earlier "deadlock: hidden section
    has no way to add the first field" trap for person contacts.
11. **`contactType` writes-through-unchanged**: the editor never
    mutates `edited.contactType`, but `apply(_:to:)` always writes
    `mutable.contactType`. A concurrent external change to
    `contactType` between load and save (rare; e.g. another device
    via iCloud) is silently reverted. Consistent with wholesale-
    overwrite semantics elsewhere; called out so it's not surprising.
