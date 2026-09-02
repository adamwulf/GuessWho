# Plan: favorite a department of an organization

## Status (2026-09-02)

BUILT on `agent/favorite-organization-dept`; awaiting promotion to `main`
and a hand check on Catalyst. All three steps landed, each after an
independent review: step 1 (package + wire + compile floor, a567678), step 2
(star affordances, 38cfb94), step 3 (sidebar nesting, 85734a8). This
document answers "can a department be favorited, and shown in the sidebar
under its organization?" The answer is yes. No new storage concept was
needed. The work is a new favorite kind plus one extra nesting level in the
Catalyst sidebar.

### Accepted behaviors noted in review

- **Sidebar root reorder normalizes grouped order.** Dragging an org row in
  the sidebar rewrites that section's slots as blocks (org, then its
  departments). If a department had been favorited BEFORE its org, the flat
  Favorites list and `favorites_list` afterwards show the org first. Display
  in the sidebar is unchanged; accepted.
- **Main-thread favorite reads on the org page.** `departmentRow` reads
  `Favorites.json` through a coordinated read during body evaluation, exactly
  as `groupRow` already does. Same cost class as groups; a follow-up could
  serve both from the in-memory `FavoritesListStore.items` if it ever shows
  up in profiling.
- **Restoration returns to the org, not the department.** Only contact and
  event selections stamp restoration state, so a relaunch after clicking a
  department child lands on the organization detail.
- **Hand check still owed on Catalyst:** drag-reorder of org rows with nested
  department rows present. The drop-index translation now lives in the pure
  `SidebarFavoriteHierarchy.rowsAfterMoving(_:from:rowStarts:toVisibleIndex:)`
  and is unit-tested (own index, later root, inside a subtree, past the last
  root, up/down corrections, self-drop, contiguous == flat); the UIKit
  index-path plumbing around it is not exercised by automation.

### Test coverage added after the build (2026-09-02)

Five gaps closed, each reviewed: the drop-index helper above (7 app tests);
MCP clear paths (emptied department still clears; org gone clears via the
stored-row fallback while an add errors; an add for a department no one
carries is `notFound`, writes nothing, and does NOT mint the org); the
phantom flow at the package level (`createContact` mints, then
`setDepartmentFavorite` resolves, phantom gone); the department rename tool
re-keys the favorite end to end (new name, same slot, `addedAt` kept); and a
mixed contact/department/group `favorites_list` keeps the department row in
stored order and pages it exactly once.

### Decisions locked (2026-09-01, Adam)

1. **The org row is inferred, never written.** Favoriting a department never
   writes a second `contact` favorite for the organization. The sidebar shows
   the org row because a department under it is favorited (§6).
2. **A department with no members shows "Unavailable"**, and the row stays
   tappable so the user can un-favorite it (§3).
3. **Phantom organizations CAN have a favorited department.** Favoriting a
   department on a phantom page first creates the real organization record,
   then favorites the department on that record (§4a). The favorite is
   therefore always a normal department favorite keyed on a real org UUID.

The motivating case: the user has a "Rice University" organization record
with four departments and wants to favorite "Lilie" so the sidebar shows
Rice University with Lilie indented under it.

## What a department is today

A department is NOT a record. It is a string on each person's Contacts card
(`Contact.departmentName`)[^1]. An organization's department list is derived
on the fly: the distinct, trimmed, case-insensitively de-duplicated
department names carried by the people whose "company" field names that
organization[^2]. A department's members are the subset of those people whose
department field matches, trimmed and case-insensitive[^3].

The app already navigates to a department with a composite key: the
organization's opaque `ContactID` plus the department name as typed. The same
department string under a different organization is a distinct
destination[^4]. That composite is the natural favorite key as well.

Departments can be renamed. The rename rewrites the department field on every
matching person and posts one reload[^5]. Both the in-app "Edit" button on the
department list[^6] and the MCP department-rename tool[^7] funnel through that
one repository method, so a favorites fix-up placed there covers both.

## How favorites work today

`Favorites.json` is one ordered array of `Favorite` values, each a `kind`, a
lowercased `id` string, and an `addedAt` date[^8]. The kinds are `contact`,
`event`, `group`, `guide`, `place`[^9]. The store lowercases every id on
write and compares `(kind, id)` pairs for toggle / set / remove[^10]. Nothing
in the store validates that an id is a UUID; the "always a UUID" statement is
a documentation convention[^8], not enforced code. The single-file store,
its coordinator, and its reorder primitive are id-shape agnostic[^10].

The package projects favorites into rows with `favoriteListItems`, a switch
over `FavoriteKind` that resolves each favorite's payload (contact, event,
group, guide, or place) and yields exactly one row per favorite, unresolvable
ones included, so the row can still be un-favorited[^11]. `FavoriteListItem`
carries one optional payload per kind[^12].

The Catalyst sidebar is an outline built with
`NSDiffableDataSourceSectionSnapshot`: each `SidebarTab` is a parent row and
each favorite hangs under its section as an indented child[^13]. A contact
favorite is placed under People or Organizations by `contactType`[^14].
Clicking a child does what clicking that record's row in its section list
does: mount the section list, select the row, show the detail[^15]. Children
can be dragged among siblings of the same section only; the drop rewrites
only that section's slots in the global array[^16].

The flat Favorites list (the iPhone tab and the Catalyst Favorites section)
renders one cell per kind with an icon, a title, and a caption[^17], and
routes selection through per-kind callbacks[^18].

The group kind is the closest precedent for a non-contact favorite: the
write path lives in the repository (`setGroupFavorite`), which serializes
mutations and keys the favorite on a durable id[^19]; the read path resolves
that id back to a live record (`group(forFavoriteID:)`)[^20]. The UI offers
the star in two places: a nav-bar star button on the members list[^21] and a
context menu on the group row of a contact's detail page[^22].

The CLI/MCP layer mirrors `FavoriteKind` with `WireFavoriteKind`[^23] and
maps between them in two exhaustive switches[^24]. Adding a package kind
without touching those switches fails to compile, so the wire layer cannot be
forgotten.

## Design

### 1. New kind and composite key

Add `FavoriteKind.department`. Its `id` is the organization's GuessWho UUID
followed by a separator and the department name:

```
<org guesswho uuid (36 chars)>/<department name>
```

The store lowercases the whole string[^10]. That is harmless: department
matching is already trimmed and case-insensitive[^3], and the display form is
re-read from live data on resolve (see §3). Parse the key by the fixed
36-character UUID prefix, never by searching for the separator, so a
department name that itself contains "/" still round-trips. Provide the
encode/parse pair as one small package type (e.g. `DepartmentFavoriteKey`)
and use it everywhere; no call site should build the string by hand.

Why the org UUID and not the org name: this is exactly the identity
`DepartmentReference` already uses[^4], and the UUID is cross-device stable
while the name is not. Why no minted "department identity" sidecar (the
approach groups needed[^25]): groups have no cross-device id of their own, but
a department is fully identified by a cross-device org id plus an Apple-synced
string. There is nothing to reconcile.

The org must have a GuessWho UUID before its department can be favorited.
The contact favorite path already resolves-or-mints that UUID on first
write[^26]; the department write path must do the same
(`resolveOrMintGuessWhoID(for:)`).

### 2. Write path (package)

Add to `ContactsRepository`, mirroring the group pair[^19]:

- `isDepartmentFavorite(_ department: String, in organization: Contact) -> Bool`
- `setDepartmentFavorite(_ favorite: Bool, department: String, in organization: Contact) async throws -> Bool`

`set` resolves-or-mints the org's GuessWho UUID, builds the key with the
trimmed department name, and calls the store's idempotent `set`[^10].

Hook `renameDepartment(from:to:in:)`[^5]: after the member saves succeed,
rewrite any `.department` favorite keyed on `(org, oldName)` to
`(org, newName)`, preserving its slot and `addedAt`. Without this the
favorite goes "Unavailable" the moment the user renames the department.
Use `loadAll` + in-place replace + `setAll`[^10]; the reorder primitive is
the wrong tool because it refuses any change other than order.

### 3. Read path (package)

Add a `department` payload to `FavoriteListItem`[^12], a small struct holding
the resolved organization `Contact` and the department name in its live
display form. Add the `.department` case to `favoriteListItems`[^11]:

1. Parse the key. Unparseable → nil payload ("Unavailable").
2. Resolve the org by GuessWho UUID. Missing → nil payload.
3. Find the live department whose trimmed lowercase equals the key's name
   in `departments(in: org)`[^2]. Missing → nil payload.

Rule 3 is deliberate: departments exist only through people. An organization
page hides a department the moment no associated person carries it[^27], so
a favorite of that department reads as unavailable, and the user can remove
it from the row. Using the live match also restores the user's capitalization,
which the lowercased key lost.

### 4. Where the star lives (app)

Two affordances, both mirroring the group precedent:

- **Department members list**: a star bar button next to "Edit" in
  `DepartmentMembersListViewController`, like the group members list's
  `favoriteBarButton`[^21]. The list already observes `.favoritesDidChange`
  to repaint its member stars[^28]; the same observer refreshes the button.
- **Organization detail page**: a context menu (Favorite / Unfavorite) and a
  trailing star on each department row, like `groupRow`[^22]. Today
  `departmentRow` is a plain push button with no menu[^29].

### 4a. Phantom organizations: create the record, then favorite

A phantom has no record and no UUID[^30], so a department favorite cannot be
keyed on it directly. Instead, the phantom page's department rows get the
same Favorite context menu as the real org page. Favoriting runs two steps in
one action:

1. Create the real organization record with the phantom's display name, the
   same call the page's "Create organization card" button makes[^39].
   `createContact` mints the GuessWho identity as part of the create[^40].
2. Call `setDepartmentFavorite(true, department:, in: created)` on the
   returned record.

This stays inside the phantom rule "nothing mutates Contacts until the user
taps an action" — the favorite IS the tap. The page already re-renders as the
real `ContactDetailView` the moment a record with that name exists[^41], so
the user lands on the real org page with the department row starred. An
"Unfavorite" action is never shown on a phantom, since no favorite can exist
without a record. If the create succeeds and the favorite write fails, the
record stays (a created card is not undone) and the error surfaces like the
other best-effort favorite writes.

### 5. Flat Favorites list (iPhone tab and Catalyst Favorites section)

One new cell case in `FavoriteCell.configure`[^17]: icon `person.2` (the
department row's icon on the org page[^29]), title = department name,
caption = organization name. Unavailable form: "Unavailable" / "Department",
matching the other kinds. One new callback, `didSelectDepartment`, alongside
the existing five[^18]. The scene delegate wires it to the existing pushes:
`pushDepartmentMembers` on iPhone and, for the Catalyst Favorites section,
the secondary-column `pushCatalystDepartmentMembers`[^31]. Both constructors
already exist and take the same `DepartmentReference`-shaped inputs.

### 6. Sidebar nesting (Catalyst)

This is the part the user described: Organizations → Rice University → Lilie.

`NSDiffableDataSourceSectionSnapshot.append(_:to:)` nests to any depth, so
the org row becomes a parent of its department rows inside the existing
single-section snapshot[^13].

**Which org rows appear.** Under Organizations, show an org row when the org
is itself favorited OR any of its departments is. The row renders
identically in both cases (name, avatar), so nothing signals "this one is
only here because of its department". Clicking it opens the org exactly as a
favorited org does today[^15]. Unfavoriting an org that still has a favorited
department leaves the row in place until the last department is unfavorited.

Recommendation: derive the org row; do NOT silently write a second
`contact` favorite when a department is favorited. A hidden write is a
surprise on the Favorites list and on the CLI, and it breaks the
one-favorite-one-row contract[^11].

**Item identity.** `SidebarViewController.Item` gains a case for a
structural (non-favorited) org parent keyed by `ContactID`, e.g.
`.organization(ContactID)`; a favorited org keeps `.favorite(id)`. Department
children are `.favorite(id)` like every other favorite. `rebuildFavoriteChildren`
builds a per-org `[ContactID: [FavoriteListItem]]` from the `.department`
items and attaches them under whichever org row exists[^32].

**Expansion.** Org rows start expanded and stay expanded; do not extend the
double-click toggle or the persisted closed-set to them. The section badge
("2 ★" when a section is closed)[^33] counts department favorites too, since
they are hidden along with everything else.

**Drag reorder.** Department rows reorder only among sibling departments of
the same org; structural org rows vend no drag items (like section parents
today)[^16]. `insertionRange` and the sibling list generalize from
`favoriteChildren[tab]` to "the sibling list the dragged row belongs to".
`FavoritesOrder.reordered` needs no change: it refills exactly the slots the
given ids occupy[^34].

**Click.** `SidebarSelection.favorite(item, in: .organizations)` with a
`.department` payload: mount the Organizations list, select the org row, show
the org detail, then push the department members list onto the secondary
nav via `pushCatalystDepartmentMembers`[^31]. That is exactly what clicking
the department row on the org page does[^29], which keeps the sidebar's
"a child does what its list row does" rule[^15]. Note the department list is
not a restorable selection today (only contacts and events stamp
restoration)[^35]; restoration will come back to the org, not the department.
Acceptable for v1.

**Context menu.** `FavoriteContextMenuRouter` switches over kind[^36]; the
`.department` case returns nil (no row menu), as events, guides, and places
do. The star toggle for a department lives on the department list and the org
page (§4), not in the sidebar.

### 7. CLI / MCP wire

`WireFavoriteKind` gains `department`[^23]; both exhaustive mappers in
`ToolDispatcher` gain the case[^24]. `MCPAuditEntry.SubjectKind` is a string
enum; add `department` (additive, Codable-safe)[^37]. `favorites_list` must
project the new kind in its stored position, never drop it (the wire
contract already says stale referents stay with `isAvailable == false`[^38]).
`favorites_set(kind: "department", id: …)` needs an id syntax; the natural
one is the wire contact id of the org plus the department name, resolved
through the same key type as the app. Document the shape in `docs/cli-mcp.md`
next to the other favorite kinds. The audit `renameDepartment` entry is
unchanged; the favorite re-key rides inside the repository call it already
records[^7].

## Package API contract

Fixed here so the parallel app phases agree on names.

```swift
// Sources/GuessWhoSync/Favorite.swift
public enum FavoriteKind { …; case department }

// Sources/GuessWhoSync/DepartmentFavoriteKey.swift (new)
public struct DepartmentFavoriteKey: Hashable, Sendable {
    public let organizationGuessWhoID: String   // lowercased UUID string
    public let department: String               // trimmed, as given
    public init(organizationGuessWhoID: String, department: String)
    /// "<uuid>/<department>" — what goes into Favorite.id (the store lowercases it).
    public var favoriteID: String
    /// Parses by the fixed 36-char UUID prefix + "/" — nil for anything else.
    public init?(favoriteID: String)
    /// Trimmed, case-insensitive department comparison.
    public func matches(department: String) -> Bool
}

// Sources/GuessWhoSync/FavoriteListItem.swift
public struct DepartmentFavorite: Hashable, Sendable {
    public let organization: Contact
    public let department: String   // live display form from departments(in:)
}
extension FavoriteListItem { public let department: DepartmentFavorite? }

// Sources/GuessWhoSync/ContactsRepository.swift
public func isDepartmentFavorite(_ department: String, in organization: Contact) -> Bool
@discardableResult
public func setDepartmentFavorite(_ favorite: Bool, department: String, in organization: Contact) async throws -> Bool
```

`setDepartmentFavorite` resolves-or-mints the org UUID (like
`toggleFavorite(_:)`[^26]), trims the department, refuses a blank one, calls
the store's idempotent `set`[^10], and refreshes the cache if it minted.
`isDepartmentFavorite` reads only: an org with no GuessWho UUID is `false`.

## Build order

Every commit must leave BOTH the package and the App target compiling. Adding
a `FavoriteKind` case breaks every exhaustive switch in the app (the Favorites
list cell and selection[^17][^18], the sidebar content and section
mapping[^14], the context-menu router[^36]) as well as the two MCP
mappers[^24]. Step 1 therefore carries the minimal app-side cases too.

1. **Package + wire + compile floor** (one agent): `FavoriteKind.department`,
   `DepartmentFavoriteKey`, `DepartmentFavorite` payload, `favoriteListItems`
   case, `isDepartmentFavorite` / `setDepartmentFavorite`, rename re-key.
   Wire: `WireFavoriteKind.department`, both mappers, `SubjectKind`,
   `favorites_list` projection, `favorites_set` id syntax (org wire id +
   "/" + department, mirroring the key), `docs/cli-mcp.md`. App compile
   floor: router returns nil; Favorites list renders a department row
   (title = department, caption = org) and gains `didSelectDepartment`
   (wired to nothing yet is NOT acceptable — wire it to the existing pushes);
   sidebar places a department favorite under `.organizations` as a plain
   child (nesting comes in step 3). Tests: store round-trip with the new
   kind, key encode/parse (including a "/" inside the department name),
   resolution (resolves / org gone / department emptied), rename re-keys and
   preserves slot + `addedAt`, org without a GuessWho UUID mints on first
   favorite, wire projection.
2. **App, flat surfaces** (parallel with 3): department list star button,
   org-page row menu + star, phantom-page row menu with create-then-favorite
   (§4a).
3. **Sidebar nesting** (parallel with 2): structural org rows, department
   children, badge count, drag rules, click routing (§6).

Each step gets its own review cycle before merge.

## Limitations of this research

- Nothing was built or compiled; the outline depth claim rests on the
  documented API of `NSDiffableDataSourceSectionSnapshot` and on the sidebar
  already using `append(_:to:)` for one level[^13].
- Sidebar behavior has no automated tests today (no App test touches
  `SidebarViewController`), so step 3 will be verified by hand on Catalyst.

[^1]: [Contact model, department field](../Sources/GuessWhoSync/Contact.swift:Contact.departmentName)
[^2]: [Distinct departments derived from associated people](../Sources/GuessWhoSync/ContactsRepository.swift:ContactsRepository.departments(inOrganizationNamed:))
[^3]: [Members of one department, trimmed + case-insensitive](../Sources/GuessWhoSync/ContactsRepository.swift:ContactsRepository.contactsAssociated(with:inDepartment:))
[^4]: [DepartmentReference: org ContactID + department string](../App/GuessWho/Support/NavigationReferences.swift:DepartmentReference)
[^5]: [Department rename rewrites each matching person](../Sources/GuessWhoSync/ContactsRepository.swift:ContactsRepository.renameDepartment(from:to:in:))
[^6]: [In-app rename from the department list's Edit button](../App/GuessWho/DepartmentMembersListViewController.swift:DepartmentMembersListViewController.performRename(to:))
[^7]: [MCP department rename calls the same repository method](../Sources/GuessWhoMCPCore/ToolDispatcher.swift:ToolDispatcher.organizationsRenameDepartment)
[^8]: [Favorite: kind, lowercased id, addedAt](../Sources/GuessWhoSync/Favorite.swift:Favorite)
[^9]: [FavoriteKind cases](../Sources/GuessWhoSync/Favorite.swift:FavoriteKind)
[^10]: [FavoritesStore: toggle / set / remove / reorder / setAll](../Sources/GuessWhoSync/FavoritesStore.swift:FavoritesStore)
[^11]: [favoriteListItems: one row per favorite, kind switch](../Sources/GuessWhoSync/ContactsRepository.swift:ContactsRepository.favoriteListItems(from:event:guide:place:))
[^12]: [FavoriteListItem payloads](../Sources/GuessWhoSync/FavoriteListItem.swift:FavoriteListItem)
[^13]: [Sidebar outline: sections as parents, favorites appended as children](../App/GuessWho/SidebarViewController.swift:SidebarViewController.applySnapshot(animated:))
[^14]: [Section for a favorite; contact splits by contactType](../App/GuessWho/SidebarViewController.swift:SidebarViewController.section(for:))
[^15]: [A favorite child does what its list row does](../App/GuessWho/GuessWhoSceneDelegate.swift:GuessWhoSceneDelegate.showFavoriteChild(_:in:split:appDelegate:))
[^16]: [Drag among siblings of one section only](../App/GuessWho/SidebarViewController.swift:SidebarViewController.collectionView(_:performDropWith:))
[^17]: [Favorites list cell, per-kind configure](../App/GuessWho/FavoritesListViewController.swift:FavoriteCell.configure(with:photoLoader:guidePlaceCount:))
[^18]: [Favorites list per-kind selection callbacks](../App/GuessWho/FavoritesListViewController.swift:FavoritesListViewController.didSelectContact)
[^19]: [Group favorite write path, serialized, keyed on durable id](../Sources/GuessWhoSync/ContactsRepository.swift:ContactsRepository.setGroupFavorite(_:for:))
[^20]: [Group favorite read path](../Sources/GuessWhoSync/ContactsRepository.swift:ContactsRepository.group(forFavoriteID:))
[^21]: [Group members list star bar button](../App/GuessWho/GroupMembersListViewController.swift:GroupMembersListViewController.toggleGroupFavorite)
[^22]: [Group row context menu Favorite / Unfavorite on contact detail](../App/GuessWho/ContactDetailView.swift:ContactDetailView.groupRow(_:))
[^23]: [WireFavoriteKind](../Sources/GuessWhoMCPWire/WireDTOs.swift:WireFavoriteKind)
[^24]: [Exhaustive FavoriteKind → wire / audit mappers](../Sources/GuessWhoMCPCore/ToolDispatcher.swift:ToolDispatcher.wireFavoriteKind(_:))
[^25]: [Group favorite identity plan: why groups needed a minted identity](group-favorite-identity.md)
[^26]: [Contact favorite resolves-or-mints the GuessWho UUID first](../Sources/GuessWhoSync/ContactsRepository.swift:ContactsRepository.toggleFavorite(_:))
[^27]: [Org page hides the Departments section when no person names one](../App/GuessWho/ContactDetailView.swift:ContactDetailView.departmentsSection(_:))
[^28]: [Department list observes favoritesDidChange](../App/GuessWho/DepartmentMembersListViewController.swift:DepartmentMembersListViewController.observeRepositoryReloads)
[^29]: [Department row: plain push button, person.2 icon](../App/GuessWho/ContactDetailView.swift:ContactDetailView.departmentRow(_:organization:))
[^30]: [Phantom organization page lists departments as plain text](../App/GuessWho/PhantomOrganizationDetailView.swift:PhantomOrganizationDetailView)
[^31]: [Catalyst push of the department members list](../App/GuessWho/GuessWhoSceneDelegate.swift:GuessWhoSceneDelegate.pushCatalystDepartmentMembers(ref:on:appDelegate:))
[^32]: [rebuildFavoriteChildren: per-section children maps](../App/GuessWho/SidebarViewController.swift:SidebarViewController.rebuildFavoriteChildren)
[^33]: [Closed-section badge counts hidden favorites](../App/GuessWho/SidebarViewController.swift:SidebarViewController.favoritesCountAccessory(count:))
[^34]: [FavoritesOrder refills only the slots the given ids occupy](../Sources/GuessWhoSync/FavoritesOrder.swift:FavoritesOrder.reordered(_:sectionOrder:))
[^35]: [Only contact and event selections stamp restoration](../App/GuessWho/GuessWhoSceneDelegate.swift:GuessWhoSceneDelegate.noteSelectionShown)
[^36]: [FavoriteContextMenuRouter kind switch](../App/GuessWho/FavoriteContextMenuRouter.swift:FavoriteContextMenuRouter.configuration(forRowAt:))
[^37]: [MCP audit SubjectKind](../Sources/GuessWhoMCPCore/MCPAuditLog.swift:MCPAuditEntry.SubjectKind)
[^38]: [WireFavorite: stale referents stay in position, isAvailable false](../Sources/GuessWhoMCPWire/WireDTOs.swift:WireFavorite)
[^39]: [Phantom page create action](../App/GuessWho/PhantomOrganizationDetailView.swift:PhantomOrganizationDetailView.createCard(name:))
[^40]: [createContact stamps timestamps, which mints the GuessWho identity](../Sources/GuessWhoSync/ContactsRepository.swift:ContactsRepository.createContact(_:))
[^41]: [Phantom page becomes the real card once a record with the name exists](../App/GuessWho/PhantomOrganizationDetailView.swift:PhantomOrganizationDetailView.body)
