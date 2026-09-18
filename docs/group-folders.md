# Group folders

Folders organize groups. A folder can hold folders and groups; a group is always
a leaf and holds contacts. Selecting a group shows its members. Selecting a
folder shows everyone in **every group beneath it**, at any depth, each person
once. Folders exist only in GuessWho — Contacts.app has no such concept — and
nothing about how they are stored is visible to the user: the UI speaks of
folders, groups, and the top level.

Read this before touching the Groups list, group identity, the group hierarchy
storage, or a folder's member list. The build plan, with the decisions behind
these rules, is [`plans/group-folders.md`](../plans/group-folders.md).

## The three layers

| Layer | Owns | Where |
| --- | --- | --- |
| Storage | The reserved cells, their stamps, and the guards against untrustworthy data. Knows nothing of the tree. | `GroupFolder.swift`, `GuessWhoSync+GroupFolders.swift` |
| Projection | The tree, as a pure function of the stored parent assignments and this device's groups. Repairs nothing. | `GroupFolderTree.swift` |
| Repository | The published snapshot, the serialized commands and their validation, and the member read. | `ContactsRepository.swift` |

The app receives immutable snapshots and calls repository commands. Views never
read hierarchy files.

## Storage

The relationship has **one** stored source of truth: a child's `parentFolder`
cell names its parent folder[^1]. A folder stores no list of children and a
group stores no path; the tree is always derived.

- A **folder** is an envelope of kind `.groupFolder`, stored under
  `group-folders/`[^2]. Its name, its parent, and its deletion marker are
  separate cells[^3], so a rename, a move, and a delete merge independently.
- A **group's** placement is a `parentFolder` cell on its existing
  `GroupIdentity` envelope, beside the identity cell[^3]. Writing a placement
  never touches the identity cell, and an identity refresh preserves the
  placement cell[^4].
- A missing placement means the top level. **Clearing** a parent writes a newer
  null and keeps the cell[^5]: an absent cell could not beat an older
  assignment that syncs in later.
- A **deletion marker** records where the folder's contents were promoted to[^6].
  Its presence deletes the folder whatever name or parent writes arrive later,
  and it is never removed. Children still naming a deleted folder resolve
  through the marker, so deleting a folder rewrites no other file.
- Placement and deletion **stamps** are strictly later than every observed
  assignment at millisecond precision — the precision that survives the wire —
  and are round-tripped through the persisted format before use[^7]. The writer
  token is `deviceID/operationUUID`[^8], so two writes from one device in one
  millisecond still order, and a retried write recognizes that it already
  landed[^5].

### Untrustworthy data

The envelope codec drops a cell that is malformed at the cell level and counts
it[^9]. For most kinds a dropped cell is treated as absent. In the hierarchy it
could be a deletion marker or a placement, so an envelope that decoded with
drops is handled differently:

- it is **excluded** from the hierarchy snapshot and reported as unavailable[^10];
- every hierarchy writer **refuses to write through it**[^11], including
  `writeGroupIdentity`, which shares the group's envelope[^4];
- conflict reconciliation **refuses to fold it**: the resolver throws, so the
  store writes nothing and keeps every version for repair[^12].

A reserved cell that is structurally valid but carries an unknown inner field,
type, or payload makes the record unavailable too; it is never read as though the
cell were absent[^13]. Every other cell in these envelopes stays opaque and is
carried through untouched, per the
[sidecar forward-compatibility contract](sidecar-compatibility.md).

A key whose read **failed** (not downloaded yet, timed out) is unknown, not
gone: it marks the snapshot incomplete[^10], and the repository keeps that
record's last good value in the tree[^14].

### Older builds

An older build has no kind for `group-folders/`. Every store operation names
its directories through `SidecarKind`[^2][^15], so a directory a build does not
know is never listed, read, written, or removed by it. The file watcher maps
such a path to no key and no kind[^16], which makes the batch globally unknown:
each repository does one debounced, read-only reload. Nothing on that path
writes, so nothing loops. `SidecarStoreCompatibilityTests` proves both
properties with a directory name no build knows, and
`GroupFolderWireFixtureTests` freezes the bytes this feature puts on the wire
(append-only: never edit a shipped fixture to make a test pass).

## Group identity is its own layer

Whether a group is in a folder does **not** affect how a device resolves that
group's identity. A group has one `GroupIdentity`, shared by favorites and
folder placement; see
[`plans/group-favorite-identity.md`](../plans/group-favorite-identity.md) for
the resolution algorithm, which folders did not change.

- **Every** stored identity resolves, whatever refers to it[^17]. A favorite is
  never inferred from a resolved identity: `isGroupFavorite` asks the favorites
  store[^18].
- Resolution also runs when a `.group` file **arrives while the app is
  running**. That watcher path is otherwise read-only; resolution is its one
  bounded exception, and the pass never refreshes fingerprints[^19].
- Resolution waits until a complete group fetch has been published, because
  before that the group cache is empty and every pin would look dead[^17].
- Moving a group looks its identity up exactly as favoriting does and mints one
  only when the group has none, so a group never gets a second identity and a
  favorited group stays favorited[^20]. Moving a group that has no identity to
  the top level mints nothing.
- When two identities resolve to one group (two devices first-touched it before
  they synced), every lookup uses the smallest identity UUID[^21].
- A placement whose identity resolves to **no group on this device** produces no
  row. The Groups list shows only groups that exist here; the stored placement
  stays intact and applies when the identity resolves later.

Concurrent-change mismatches (one device favorites a group while another
renames it) are accepted; only the golden cases in the plan are promised.

## The tree

`GroupFolderTree` is deterministic — the same records and groups give an equal
tree in whatever order they are supplied — and every traversal is iterative, so
depth costs memory, not stack[^22]. It builds in this order[^23]:

1. Resolve each child's stored parent to an **effective** parent. A deleted
   folder redirects through its marker, following chains with a visited set; a
   redirect loop falls back to the top level. A parent that is simply not here
   is **unknown, not deleted**: the child waits at the top level provisionally
   and keeps its assignment.
2. Break cycles among live folders by suppressing exactly the **oldest** edge of
   each, ordered by (placement stamp, writer, child, parent). Every folder has
   one parent, so cycles are disjoint; an edge that only leads into a cycle is
   never suppressed.
3. Sort children by the Groups list's existing comparison at every level,
   folders and groups mixed, equal names ordered by typed node id.

The projection is read-only. A suppressed or redirected assignment stays stored
as it was and takes effect again when another edge changes; `PlacementStatus`
reports what happened to each node[^24]. "Move to Top Level" is how a user
settles such an item for good[^25].

`visibleRows(collapsed:)` flattens the tree with depth, immediate child count,
and expansion[^26]. Collapsing changes only which rows appear — never
`descendantGroupLocalIDs(ofFolder:)`.

## Commands

All folder commands run on the repository's group-mutation chain. Each re-reads
the hierarchy, validates against it, and writes with no suspension between[^27].
Failed or superseded command reads abort the mutation; retained display data
cannot authorize a write. A later retry must obtain a fresh read[^27].

- A destination must be a live, readable folder[^28].
- A folder cannot move into its own subtree, and a move is also refused when the
  tree it would produce does not put the folder where asked, or knocks another
  folder out of place[^29].
- Deleting a folder records its **effective** parent as the promotion
  destination[^30]. Groups and contacts are untouched.
- `createGroup(name:inFolder:)` creates the Contacts group first. If placing it
  then fails it throws `GroupPlacementFailedError` carrying the group, so a
  retry places **that** group instead of creating a duplicate[^31].
- `deleteGroup` throws only when the group was **not** deleted. Once Contacts
  has deleted it, the identities that resolved to it (captured before the
  delete) have their placement cleared with a stamp later than every placement
  seen, so a later same-named group that adopts the identity starts at the top
  level. That clear can fail on its own; it is returned as a
  `PendingGroupPlacementCleanup` for `retryGroupPlacementCleanup(_:)`, never
  reported as a failed delete[^32]. The identity record itself is left in place,
  as it is for a favorite.

## A folder's members

`memberSnapshot(for:)` takes a `GroupMemberScope` — a group, or a folder — and
returns a `GroupMemberSnapshot`[^33]. It never throws and mints nothing.

- Each group in scope is fetched once, a bounded number at a time, and the
  results are combined in **tree order, not completion order**[^33][^34].
- One person reached through several groups is normalized, for that request
  only, by the Contacts handle the fetches share, to the repository's current
  record; when two fetches disagree about a contact the repository does not
  cache, the record is re-read. If that read fails or returns no contact, the
  unresolved member is omitted and its contributing groups are reported as
  partial, rather than choosing a stale identity[^33]. The union is then taken by `ContactID`.
  Contacts are never merged by name or email. This keeps the
  [identity contract](contact-identity.md): the handle is never a key the app
  sees.
- A group whose fetch fails is reported in `failedGroups`; `emptiness` separates
  a folder with no groups, groups with no members, and nothing to show because a
  fetch failed[^35]. A partial result is never labeled as complete.
- A folder read is also partial when hierarchy enumeration, a placement, a
  placed group's identity, or a folder record is unavailable. Missing hierarchy
  can hide whole groups, so `hierarchyIsComplete` records this even when
  `failedGroups` is empty[^33][^35].
- A multi-fetch read is not a transaction. The snapshot records the hierarchy,
  membership, and contact-data revisions it started from, and `isCurrent(_:)`
  says whether any moved[^36]. A caller discards a snapshot that spans a change
  and reads again.

Folder-member pagination also binds its cursor to a fingerprint of the ordered
contact rows and the groups that failed to load. A transient fetch failure or
recovery can change that result without changing repository revisions. The next
page rejects such a cursor, so the caller restarts instead of skipping or
repeating contacts. An unchanged partial result remains pageable[^46].

## UI

The Groups list renders the tree[^37]. The rules that need no table view are
pure types, tested in the app bundle (`GroupFolderPresentationTests`):

- **Rows** are keyed by a typed id and compared by their whole render state, so
  a rename, a new depth, a changed count, or a folder opening finds the row to
  reconfigure[^37]. A closed folder with contents shows a count of its
  **immediate items** (folders plus groups), worded for assistive technology so
  it cannot be taken for a count of contacts[^38]. The drawn indent is capped by
  the width; the true depth and the full path stay in the accessibility
  label[^38].
- **Expansion** is remembered per device as the set of **closed** folders, so a
  folder that is new here starts open and closing a parent never forgets its
  children[^39]. The disclosure control toggles and never navigates.
- **Selection.** A group opens its members at once. A folder opens the same
  member list over every group beneath it. On Mac Catalyst a folder's single
  click is held for the double-click interval, because opening pushes the member
  list over the tree and a double click (expand or collapse) has to be ruled out
  first[^40]. Returning from members preserves the selected tree row, including
  the destination used by New Folder and New Group[^37].
- **Drag and drop** is local and single-item. A folder's center means move
  inside. A gap means out to the top level **only** at the boundary of a
  top-level branch: siblings are alphabetical, so a gap inside a folder would
  imply an order the list does not have[^41]. Drops and the "Move to…" menu go
  through one call, so both are validated and reported the same way[^42].
- **Member list.** A folder reuses the group member list with no favorite star,
  a "Some groups couldn’t be loaded." banner with Retry for a partial result,
  and a return to the tree when its folder is deleted[^43][^44]. Reloading also
  reconfigures retained rows whose contact contents changed, so edits repaint
  without replacing their row identities[^43]. The loader preserves the last
  accepted rows while retrying stale reads, pausing briefly after three stale
  reads to avoid a tight loop. It checks scope availability after the first
  load too: only a deletion marker navigates away. An unavailable folder keeps
  the accepted rows with a warning and Retry until it can be read again[^47].
- **Add to Group** nests folders as submenus; only groups are choices, and a
  folder with no group beneath it is left out[^45].

Version one has no manual ordering, no folder favorites, and no contact drops
onto the tree.

[^1]: [A folder record holds a parent assignment and no child list](../Sources/GuessWhoSync/GroupFolder.swift:GroupFolderRecord)
[^2]: [The one kind-to-directory mapping](../Sources/GuessWhoSync/SidecarKind.swift:SidecarKind.directoryName)
[^3]: [Reserved hierarchy cell keys](../Sources/GuessWhoSync/GroupFolder.swift:GroupHierarchyCells)
[^4]: [Identity write preserves neighbors and refuses a lossy envelope](../Sources/GuessWhoSync/GuessWhoSync+Groups.swift:GuessWhoSync.writeGroupIdentity)
[^5]: [Placement write: no-op, retry, and newer-null rules](../Sources/GuessWhoSync/GuessWhoSync+GroupFolders.swift:GuessWhoSync.writePlacement)
[^6]: [Deletion marker](../Sources/GuessWhoSync/GroupFolder.swift:FolderDeletion)
[^7]: [Strictly-later, round-tripped stamp](../Sources/GuessWhoSync/GroupFolder.swift:GroupHierarchyCells.stamp)
[^8]: [Writer token](../Sources/GuessWhoSync/GroupFolder.swift:GroupHierarchyCells.writerToken)
[^9]: [Malformed cells are dropped and counted](../Sources/GuessWhoSync/SidecarEnvelope.swift:SidecarEnvelope)
[^10]: [Hierarchy read: unavailable versus unreadable keys](../Sources/GuessWhoSync/GuessWhoSync+GroupFolders.swift:GuessWhoSync.groupHierarchyRecords)
[^11]: [Lossy-envelope write guard](../Sources/GuessWhoSync/GuessWhoSync+GroupFolders.swift:GuessWhoSync.requireLossless)
[^12]: [Conflict reconcile refuses a lossy hierarchy version](../Sources/GuessWhoSync/GuessWhoSync.swift:GuessWhoSync.reconcileSidecars)
[^13]: [Folder decode: malformed reserved cell makes the record unavailable](../Sources/GuessWhoSync/GroupFolder.swift:GroupHierarchyCells.decodeFolder)
[^14]: [Last good value kept for an unreadable record](../Sources/GuessWhoSync/ContactsRepository.swift:ContactsRepository.reloadGroupHierarchy)
[^15]: [Enumeration lists known kinds only](../Sources/GuessWhoSync/FileSystemSidecarStore.swift:FileSystemSidecarStore.allKeys)
[^16]: [Watcher directory-name mapping](../Sources/GuessWhoSync/SidecarFileWatcher.swift:SidecarFileWatcher.sidecarKind)
[^17]: [Every identity resolves; waits for an authoritative group cache](../Sources/GuessWhoSync/ContactsRepository.swift:ContactsRepository.refreshAllGroupIdentities)
[^18]: [Star asks the favorites store](../Sources/GuessWhoSync/ContactsRepository.swift:ContactsRepository.isGroupFavorite)
[^19]: [Watcher path and its one bounded write exception](../Sources/GuessWhoSync/ContactsRepository.swift:ContactsRepository.refreshFromSidecarChange)
[^20]: [Moving a group reuses or mints its identity](../Sources/GuessWhoSync/ContactsRepository.swift:ContactsRepository.moveGroup)
[^21]: [Smallest identity UUID wins the reverse pointer](../Sources/GuessWhoSync/ContactsRepository.swift:ContactsRepository.cache)
[^22]: [Tree projection contract](../Sources/GuessWhoSync/GroupFolderTree.swift:GroupFolderTree)
[^23]: [Build order: redirects, cycles, child lists](../Sources/GuessWhoSync/GroupFolderTree.swift:GroupFolderTree.init)
[^24]: [Placement status](../Sources/GuessWhoSync/GroupFolderTree.swift:GroupFolderTree.PlacementStatus)
[^25]: [When Move to Top Level is offered](../App/GuessWho/GroupFolderPresentation.swift:GroupFolderMoveTargets.offersMoveToTopLevel)
[^26]: [Flattened rows](../Sources/GuessWhoSync/GroupFolderTree.swift:GroupFolderTree.visibleRows)
[^27]: [Folder move command](../Sources/GuessWhoSync/ContactsRepository.swift:ContactsRepository.moveGroupFolder)
[^28]: [Destination validation](../Sources/GuessWhoSync/ContactsRepository.swift:ContactsRepository.validatedLiveFolder)
[^29]: [Refusing a move the tree would not honor](../Sources/GuessWhoSync/ContactsRepository.swift:ContactsRepository.requireMoveTakesEffect)
[^30]: [Folder delete records the effective parent](../Sources/GuessWhoSync/ContactsRepository.swift:ContactsRepository.deleteGroupFolder)
[^31]: [Placement failure after create](../Sources/GuessWhoSync/GroupFolder.swift:GroupPlacementFailedError)
[^32]: [Group delete and owed placement cleanup](../Sources/GuessWhoSync/ContactsRepository.swift:ContactsRepository.deleteGroup)
[^33]: [Member snapshot read](../Sources/GuessWhoSync/ContactsRepository.swift:ContactsRepository.memberSnapshot)
[^34]: [Bounded, ordered group fetches](../Sources/GuessWhoSync/ContactsRepository.swift:ContactsRepository.fetchMembers)
[^35]: [Why a snapshot is empty](../Sources/GuessWhoSync/GroupMemberSnapshot.swift:GroupMemberSnapshot.Emptiness)
[^36]: [Staleness check](../Sources/GuessWhoSync/ContactsRepository.swift:ContactsRepository.isCurrent)
[^37]: [Groups tree list](../App/GuessWho/GroupsListViewController.swift:GroupsListViewController)
[^38]: [Indent cap and accessibility label](../App/GuessWho/GroupFolderPresentation.swift:GroupFolderRowLayout)
[^39]: [Per-device expansion state](../App/GuessWho/GroupFolderPresentation.swift:GroupFolderExpansionStore)
[^40]: [Single- versus double-click arbitration](../App/GuessWho/GroupFolderPresentation.swift:GroupFolderClickArbiter)
[^41]: [Drop policy](../App/GuessWho/GroupFolderPresentation.swift:GroupFolderDropPolicy.proposal)
[^42]: [One move call for menus and drops](../App/GuessWho/GroupContextMenu.swift:GroupContextMenu.move)
[^43]: [Member list for a group or a folder](../App/GuessWho/GroupMembersListViewController.swift:GroupMembersListViewController)
[^44]: [Member list wording rules](../App/GuessWho/GroupMemberListPresentation.swift:GroupMemberListPresentation.make)
[^45]: [Add to Group nesting](../App/GuessWho/AddToGroupMenu.swift:AddToGroupMenu.groupElements)
[^46]: [Folder-member cursor validation](../Sources/GuessWhoMCPCore/ToolDispatcher.swift:ToolDispatcher.foldersListMembers)
[^47]: [Member load validation and retry](../Sources/GuessWhoSync/GroupMemberListLoader.swift:GroupMemberListLoader)
