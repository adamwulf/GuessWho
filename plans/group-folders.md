# Group folders

Status: proposed implementation plan, 2026-09-17. This is a new design; `nested-groups.md` remains unchanged as the earlier alternative. Nothing in either plan has been implemented.

## Behavior

Folders organize groups. Groups contain contacts. A folder can contain folders and groups; a group is always a leaf. Each item has one parent folder or sits at top level. Contacts cannot be added to folders, and groups cannot contain groups.

Selecting a group shows its direct members. Selecting a folder shows the union of the members of **every descendant group**, including groups inside nested folders. Each contact appears once. Expansion controls only the tree's appearance; collapsing a branch never removes its contacts from a folder's member view.

```text
Family                         folder → members of all three groups
  Immediate Family             group
  Extended Family              group
  Activities                   folder → members of Soccer Parents
    Soccer Parents             group
```

Use unlimited logical depth, alphabetical siblings (folders first, then groups), distinct folder/group icons, and indentation. Cap physical indentation on narrow screens while retaining full paths and depth in accessible labels. Folder names need not be unique; paths disambiguate them. Manual sorting, folder favorites, and contact drops onto the tree are outside version one.

## Existing foundations

- Groups are Contacts records with device-local IDs. Durable `GroupIdentity` records already support favorites, using names, membership hints, and per-device pins. They do not yet provide authoritative cross-device identity for folder placement.[^1]
- Group identity writes preserve other cells in their envelope. Existing sync merges raw cells independently by timestamp and writer string, so a separate placement cell can evolve without identity refresh overwriting it.[^2]
- The Groups table currently keys rows by local group ID. Selecting a row pushes a member list onto the same navigation stack, including Catalyst's supplementary column.[^3]
- The member controller already supplies search, sorting, photos, multi-selection, and Add to Group. It deduplicates using `ContactID`. Its current repository fetch turns errors into empty arrays, which is unsuitable for reporting a complete folder union.[^4]
- Store enumeration, directory routing, watcher path parsing, and repository relevance filtering explicitly enumerate known sidecar kinds. Adding folder storage must update each of these paths.[^5]

## Architecture and storage

Keep persistence and the pure tree projection in `GuessWhoSync`. `ContactsRepository` owns live group resolution, serialized mutations, hierarchy/member revisions, and aggregate loading. UIKit receives immutable snapshots and calls repository commands; views do not read files or construct contact identities.

| Record | Durable identity | Stored data |
| --- | --- | --- |
| Folder | New UUID; proposed `SidecarKind.groupFolder` | Separate name, parent-folder, and deletion-marker cells |
| Group | Existing `GroupIdentity.id` | New `parentFolder` cell beside `groupIdentity` |
| Contact membership | Existing Contacts group membership | No folder membership or cached union persisted |

Use `group-folders/<uuid>.json` for folder envelopes, with the existing envelope schema. Folder creation writes its name and initial parent in one envelope. Both folder and group placement cells contain a nullable folder UUID. Missing placement means top level; an explicit null or tombstoned placement is a stamped top-level assignment. Clearing a parent writes a newer null, never removes the dictionary entry. A rename only changes the name cell.

All cell writers preserve structurally valid raw neighboring cells under key locking. Names are trimmed and nonempty. A decoded cell with an unknown inner payload remains opaque; a malformed reserved placement/deletion payload makes the record unavailable rather than treating that field as absent. Identity metadata, membership changes, and starring never restamp placement.

The envelope codec drops structurally malformed cells and reports `cellsDroppedOnDecode`; it does not preserve those cells.[^10] Add a guard for every `.groupFolder` and `.group` envelope with a nonzero drop count: exclude it from authoritative tree data and block all writes through that lossy decoded map, including identity refresh. Apply this guard to every input version before conflict merge/write-back as well as ordinary mutations; keep original bytes and unresolved versions for repair. Do not reconstruct or automatically repair a possibly lost deletion marker. Retain last good UI state with an unavailable warning. Preservation of unknown valid payloads is not a promise that malformed data survives old clients; test that limit explicitly.

For placement and folder-deletion writes, choose a timestamp strictly later than all relevant observed assignments at persisted millisecond precision; round-trip it before saving. Use `deviceID/operationUUID` as the opaque writer token for these new cells so independent same-device writes at equal times still have a tie-break. A retried logical write reuses its stamped cell. No-op moves do not write. This avoids changing general merge semantics; valid-writer convergence excludes corrupted cells with identical stamps/tokens but different payloads. Reject timestamp overflow. “Oldest” below means stored assignment order, subject to clock skew.

Extend `SidecarKind`, `SidecarKey` switches, filesystem creation/listing/scoped scans, conflict reconciliation, watcher mappings, in-memory stores, and exhaustive consumers. Group placement is an additive neighboring cell. A new folder kind also needs **old-version fixtures** proving old apps leave its directory/files intact during scans, maintenance, and unrelated writes; cell forward compatibility alone does not establish this. Older versions show their existing flat groups. Do not bump envelope schema for additive cells or expose folder kinds through existing contact-link/favorite APIs accidentally.[^2][^5]

### Group identity remains the main prerequisite

Folders have native durable UUIDs; Contacts groups still need careful adoption. A successful local scan cannot prove that another device has not created an undiscovered identity. Permit duplicate group identities rather than assuming minting can be globally unique.

Add a separate, per-device binding cell on a group identity, recording its current local group handle and provenance: minted during an explicit operation on that group, or confirmed by the user. Legacy favorite pins and matching names/member fingerprints only suggest candidates. They cannot prove identity after delete/recreate. A missing bound group stays unresolved; never automatically bind a same-name replacement.

For an unresolved placed group, show a non-selectable “Group unavailable on this device” row in its folder, with a Resolve action showing the saved name/path and a picker for the current group. Confirmation establishes that device's binding; cancel preserves data. Locally available groups without trusted bindings remain reachable at root. Folder results report unavailable descendants instead of silently omitting them. No UUIDs or storage terminology appear in this UI.

Trusted identities bound to the same local group form a local alias set. Render the group once. Choose its newest placement across aliases, including stamped roots/tombstones; absence does not compete. Ties use `(modifiedAt, modifiedBy, identityID)`. Write new moves to the smallest alias UUID with a stamp newer than all observed aliases. Do not delete/rewrite identities. Other devices may need their own confirmation; identical records and bindings must produce identical placement.

Generalize identity refresh beyond favorited groups to all placed identities. Use a reverse multimap: the group's star is true if any confirmed alias is favorited; favorite reuses an existing favorite, and unfavorite clears all known confirmed aliases. Preserve existing favorite row IDs/order and row-specific removal. Unseen remote favorites can arrive later. Do not use heuristic favorite resolution to establish trusted aliases.

## Tree projection, cycles, and deletion

Proposed pure model: `GroupFolderTree`, with typed folder/group node IDs, effective parents, child lists, paths on demand, descendant group identities, and availability/conflict diagnostics. Use iterative traversal and visited sets; a 1,000-folder chain must remain usable without recursive stack growth or eagerly materializing every full path.

Local commands—create/rename/delete folder and move folder/group—run through repository mutation serialization. Validate the current snapshot immediately before writing and again after suspensions: destination exists and is a live folder; folder moves cannot target self or a descendant. Moving a folder carries its subtree. Reject unresolved required bindings or known unreadable hierarchy records. Single-key locking cannot prevent two devices from making individually valid moves that form a cycle.

Build every projected tree in this order:

1. Read locally discoverable folder records and group assignments; choose each group's alias winner once. Retain unresolved group nodes. A known download failure is incomplete data; retain the last good snapshot rather than declaring it empty.
2. Apply folder-deletion redirects described below. Follow deleted-folder chains with a visited set; a missing/malformed target or redirect loop falls back to root with a diagnostic. Unknown/download-pending is distinguished from confirmed deletion.
3. Detect cycles among effective live folder-parent edges. In each cycle suppress exactly the oldest edge by `(modifiedAt, modifiedBy, childFolderID, parentFolderID)`. Retain the originating placement stamp through redirects. Never suppress an off-cycle edge. Groups cannot participate: no edge can target a group.
4. Place items with unavailable parents at root provisionally, with status; preserve their stored assignments. Sort and flatten visible rows. Each live local group and each live folder appears once; unresolved identity rows have their own typed keys and never masquerade as resolved membership.

Suppression is read-only and deterministic, not an automatic repair write. A suppressed edge may become effective again when another edge changes. Expose “Move to Top Level” to explicitly clear it. Tests must cover this behavior and prevent a local command whose requested move is immediately suppressed.

**Deleting a folder** deletes its container only. Contents move up one level; groups and contacts survive. Persist a dedicated deletion marker containing the promotion destination captured at deletion (the folder's effective parent, or root). Marker presence makes the folder deleted regardless of later stale name/parent writes. Never remove this marker or offer restoration under the same UUID in version one.

Children still pointing at a deleted folder resolve through its recorded promotion destination; no multi-file child rewrites or cleanup journal are required. A concurrent move of a child elsewhere wins normally because its parent no longer names the deleted folder. Concurrent folder deletions choose the marker payload by normal LWW; subsequent local delete calls are no-ops. Further deletion of the promotion parent follows the redirect chain; cycles/missing targets become root. Check redirect-expanded ancestry during move validation. Explain before deletion: “The items inside will move to [parent / Top Level].”

**Deleting a group** retains Contacts deletion semantics and separate cleanup reporting.[^6] Before deletion capture its entire confirmed alias set and favorite IDs. After Contacts deletion succeeds, write a durable per-device `hiddenAfterDeletion` marker for EVERY captured alias, distinct from an absent/dangling binding. Projection checks that marker before resolving or creating an unavailable row, so reload and late file versions of those known aliases cannot resurrect it. Only explicit user confirmation can clear a hidden marker and establish a replacement binding. Keep captured IDs for retries; never retry Contacts creation/deletion or resolve by name as cleanup.

Report hidden-marker and favorite-cleanup failures independently from Contacts deletion failure; retry pending aliases by captured ID. Across-relaunch retry covers successfully saved pending work only: process death between Contacts deletion and cleanup recording is not atomic and can leave an unavailable row. Undiscovered aliases arriving later remain unresolved until explicitly confirmed or dismissed; do not guess they were deleted. Other devices retain their own bindings/availability. Never cascade-delete folders/contacts or auto-adopt a same-name replacement.

## Folder member aggregation

Introduce an error-aware repository read returning a `MemberSnapshot` for a typed group or folder scope. Return contacts, contributing groups per contact, failed/unresolved groups, and the hierarchy, membership, and contact-data/reconcile generations used. The existing empty-on-error method can remain compatible; aggregation uses a throwing/per-group-result path.

For a folder, enumerate every effective descendant group independently of expansion, deduplicate resolved group aliases, and fetch each group once with bounded concurrency. Within the package, normalize repeated unified-contact results by their transient local handle for this request only, then vend current `ContactID` values and union by those IDs. Resolve/refetch conflicting pre/post-reconcile versions through current package identity handling, including members absent from the global cache; never choose whichever async result finished last. Local handles remain an internal fetch-normalization aid, never durable identity or app keys. Reads mint nothing. Keep contacts and group provenance in memory, and rebuild after identity changes. Do not merge contacts by name/email. This respects the package/app identity boundary.[^7]

Coalesce refreshes and cancel obsolete loads. Each request captures a unique ownership token plus hierarchy, membership, and contact-data/reconcile generations; check all of them after awaits and before publication. Advance contact-data generation for contact edits, reloads, reconciliation and observed external Contacts changes even when membership did not move. Reject/reload a result spanning those changes. Refresh when descendants change, identities resolve, or Contacts changes externally. Sort/search reproject the current accepted snapshot with their own revision. Multi-fetch results are best-effort, not a database transaction; observed changes during loading schedule a fresh pass.

Show successful results with “Some groups couldn’t be loaded” and Retry if any descendant fails or is unresolved. Never label a partial result as a complete count or “No Members.” Distinguish no descendant groups, groups with zero members, search with no matches, and unavailable results. Previously loaded rows may remain visibly stale during retry but cannot be used for bulk actions as though current. Fetch lazily when a folder is selected, not for every tree row/count.

A folder has no Add Contact/Add Member or Remove from Folder operation. Add to Group remains available on contacts, using a picker where only leaf groups are selectable and folder headings provide navigation. Existing contact-detail group editing can remove a specific membership. Version one adds no ambiguous aggregate “Remove” or folder-wide email action; users open a group for its existing email command. Viewing/editing an individual contact is unchanged. Folder favorites are deferred, so folder member lists omit the group-star toolbar button.

## Groups UI

**Creation:** (+) offers New Folder and New Group. Default destination is the selected folder, the selected group's parent, or top level; show that destination in the creation prompt. A new group is created in Contacts first, then placed. If placement fails, keep the created group reachable at root and offer Retry Placement using that same group—never retry Contacts creation and duplicate it.

**Rows:** use a typed diffable ID (`folder(UUID)`, `group(localID)`, `unavailableGroup(identityID)`) and compare full render state, not only names. Show folder/group icons, indentation, and a collapsed-folder badge counting **immediate child items** (folders plus groups, including unavailable group entries). Its accessible label says “N items”; do not imply it counts contacts or all descendant groups. Hide the badge when expanded. Empty folders have no toggle/count. Remember collapsed folder UUIDs device-locally, default new folders open, and preserve descendant expansion choices.

**Selection and disclosure:** single-click/tap opens that node's member view; folder selection always aggregates nested groups. On Catalyst, double-click a folder to expand/collapse, matching the sidebar convention.[^8] Because the first click would otherwise push away from the tree, arbitrate folder pointer single/double clicks before navigation: a recognized double-click only toggles; a confirmed single-click opens members after the double-click decision. Leaf groups open normally. Accept the small folder click delay rather than adding another permanent pane. Prototype and verify this arbitration before full UI work; do not copy the sidebar's simultaneous selection callbacks unchanged.

Provide a separate disclosure target for touch plus keyboard Expand/Collapse actions and accessibility custom actions. Disclosure never navigates; double-click on that control must not toggle twice. Preserve current Catalyst/iOS member-to-contact navigation by generalizing the member-list input to group/folder and adding a folder-selection route in `GuessWhoSceneDelegate`. No new screen column is needed.[^3]

Persist expansion through reload/relaunch. Programmatic group selection expands ancestors before scrolling. Returning from members restores scroll/selection. A moved selected folder keeps its aggregate view and refreshes descendants; deleting the selected folder returns to the tree. Reset all indentation/accessibility state on reuse; verify VoiceOver, keyboard, Dynamic Type, and RTL.

**Drag/drop:** local single-item folder/group drags only. Drop onto a folder center to move inside; drop on the dedicated Top Level target to remove its parent. Root-subtree boundary gaps may also promote to root, with clear feedback. Reject group centers, self/descendant folders, unavailable nodes, foreign payloads, and nested gaps that would imply unsupported manual ordering. Contact drops onto folders are always rejected. Move to… and Move to Top Level provide the same operations without dragging.

Capture identity rather than relying on row indices, revalidate the latest graph at drop time, and persist before showing success. Expand the destination after success. A failed/cancelled drop preserves the current tree. Use subtree boundaries for root-gap hit testing and label previews with the destination; siblings remain alphabetical.

## Refresh and automation

Add hierarchy and membership revisions to the repository projection; coalesce notifications. Folder/placement watcher deliveries rebuild read-only snapshots and invalidate affected open member views, without changing contact records or photo caches. Separate binding persistence from watcher resolution. A complete local scan never promises global iCloud discovery; later arrivals can change both tree and availability.

Keep existing group CLI/MCP commands and wire IDs compatible. Add folder list/create/rename/move/delete, group move-to-folder/top-level, and folder-members reads, all through the shared validators. Folder IDs are durable UUIDs; existing group wire IDs remain device-scoped. Use typed destination fields, nullable parent-folder IDs, and explicit unavailable/partial status. Deduplicate before pagination; bind cursors to folder scope, hierarchy/membership/contact-data generations, and sort/filter parameters. Reject stale or mismatched cursors rather than skip/duplicate contacts. Identity confirmation stays in the app initially; automation gets a resolution-required error. Reject folder IDs in every contact-membership mutation. Add idempotency tokens for creates and desired-state moves, plus clear unsupported-tool errors for old helpers.[^9]

## Delivery and acceptance

1. **Storage and identity:** new folder kind/cells, trusted group bindings, alias handling, compatibility fixtures. Prove new folders survive old-version operations and unreadable data never looks like deletion. Test malformed deletion markers against stale name/parent writes and conflict resolution; malformed group placement against unrelated identity refresh; alias deletion/hiding across reload and late arrival, including partial marker failures.
2. **Tree and commands:** pure projection, serialized moves, deletion redirects, scoped refresh. Test cycles, redirect cycles, concurrent moves/deletes, timestamp ties in both merge orders, malformed data, root clears, and 1,000-depth input. Shuffling the same valid inputs yields the same forest.
3. **Aggregate members:** error-aware reads, deduplication/provenance, revisions, partial results. Test overlapping memberships, unreconciled contacts, reconciliation/contact edits during loading with unchanged memberships and older fetches finishing last, uncached members, nested folders, collapsed branches, unresolved groups, permission failures, external changes, stale completion, sort/filter cursor changes, and empty/search states.
4. **UI:** creation, mixed tree, shared member view, folder click arbitration, counts, disclosure, menus, drag/drop. Test failed placement after group creation, leaf-only Add to Group, root escape, selection restoration, and deletion while viewing members. Verify gestures on real Catalyst/iOS surfaces and assistive technology.
5. **Automation and docs:** transport/parser/paging tests, source-comment updates (including the current one-cell group-sidecar description), current behavior documentation, and independent review. Keep the original proposal for comparison.

Likely files: `SidecarKind.swift`, `SidecarKey.swift`, `FileSystemSidecarStore.swift`, `SidecarFileWatcher.swift`, new folder storage/tree types, `GuessWhoSync+Groups.swift`, `ContactsRepository.swift`, test stores, `GroupsListViewController.swift`, `GroupMembersListViewController.swift`, `GroupContextMenu.swift`, `AddToGroupMenu.swift`, `GuessWhoSceneDelegate.swift`, and CLI/MCP schemas/dispatchers. Extract shared member presentation rather than copy the existing controller wholesale.

For implementation, run targeted new suites, then `swift test`, app tests on an installed simulator, and Catalyst/iOS builds with `.build/DerivedData` inside the worktree. For example: `xcodebuild -project App/GuessWho.xcodeproj -scheme GuessWho -destination 'platform=macOS,variant=Mac Catalyst' -derivedDataPath .build/DerivedData build`. Report actual commands/outcomes and distinguish sandbox failures from source failures. This plan-only change needs citation checks and worker/sol review, not a build.

## Sources

[^1]: [Live Contacts group model](../Sources/GuessWhoSync/ContactGroup.swift:ContactGroup), [durable group identity hints](../Sources/GuessWhoSync/GroupIdentity.swift:GroupIdentity), and [current heuristic resolution](../Sources/GuessWhoSync/ContactsRepository.swift:ContactsRepository.resolveGroupIdentity)
[^2]: [Identity writes preserve neighboring cells](../Sources/GuessWhoSync/GuessWhoSync+Groups.swift:GuessWhoSync.writeGroupIdentity), [raw cell merge](../Sources/GuessWhoSync/SidecarMerge.swift:merge), and [compatibility contract](../docs/sidecar-compatibility.md)
[^3]: [Groups table and selection](../App/GuessWho/GroupsListViewController.swift:GroupsListViewController), [Catalyst group navigation](../App/GuessWho/GuessWhoSceneDelegate.swift:GuessWhoSceneDelegate.installGroupsList), and [member navigation](../App/GuessWho/GuessWhoSceneDelegate.swift:GuessWhoSceneDelegate.showGroupMembers)
[^4]: [Member-list presentation and identity map](../App/GuessWho/GroupMembersListViewController.swift:GroupMembersListViewController), and [empty-on-error member read](../Sources/GuessWhoSync/ContactsRepository.swift:ContactsRepository.members)
[^5]: [Filesystem kind routing/enumeration](../Sources/GuessWhoSync/FileSystemSidecarStore.swift:FileSystemSidecarStore), [watcher path mapping](../Sources/GuessWhoSync/SidecarFileWatcher.swift:SidecarFileWatcher.sidecarKey), and [repository sidecar relevance](../Sources/GuessWhoSync/ContactsRepository.swift:ContactsRepository.handledSidecarKinds)
[^6]: [Group deletion and separate favorite cleanup](../App/GuessWho/GroupContextMenu.swift:GroupDeletionOperation)
[^7]: [Opaque contact identity contract](../docs/contact-identity.md)
[^8]: [Sidebar double-click expansion](../App/GuessWho/SidebarViewController.swift:SidebarViewController.handleDoubleClick), and [collapsed count rendering](../App/GuessWho/SidebarViewController.swift:SidebarViewController.configure)
[^9]: [Group CLI commands](../Sources/GuessWhoCLICore/GroupsCommand.swift:GroupsCommand), and [device-local group wire IDs](../Sources/GuessWhoMCPCore/WireRecordID.swift:WireRecordID.groupID)
[^10]: [Malformed cells are dropped with a diagnostic count](../Sources/GuessWhoSync/SidecarEnvelope.swift:SidecarEnvelope)
