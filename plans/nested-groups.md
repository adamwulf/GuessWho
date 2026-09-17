# Nested groups implementation plan

Status: proposed; implementation is not part of this change.
Date: 2026-09-16.

## Recommendation

Represent group structure as a forest: each group has zero or one parent. Store a separate parent cell on the existing durable group identity sidecar. Prevent cycles in local commands and deterministically suppress the oldest edge of any cycle introduced through sync. Do not write automatic cycle repairs. User-facing copy calls this “group structure” or “grouping,” avoiding confusion with the Organizations tab.

Allow arbitrary depth in storage. Make deep trees usable with bounded visual indentation, disclosure controls, and a move picker that shows full paths. Keep siblings alphabetical initially; drag/drop changes parentage, not manual sort order.

This is a medium-sized feature spanning identity, sync projection, repository mutation, and UIKit. The parent field itself is small; reliable cross-device identity and predictable drop destinations are the substantial work. Deliver it in the phases below, with identity and convergence tests passing before UI work depends on them.

## Product contract

- Nesting organizes groups only. A parent shows its own direct contacts; it does not inherit descendants' contacts. Email, member counts, Add to Group, and membership removal retain direct-membership semantics. This avoids silently expanding email recipients.
- Moving a group carries its entire subtree. It does not rename groups, change contacts, or move Contacts accounts. The hierarchy exists in GuessWho; the underlying groups remain independent Contacts groups.
- No two- or three-level storage limit. A depth limit adds subtree-height rules to moves and sync without removing the need for cycle handling. Support at least a 1,000-node chain without recursion overflow or disappearing rows.
- Root and sibling order uses the existing name comparison with a deterministic identity/local-ID tie break. Manual ordering is a separate feature.
- Tapping a row opens members. A separate leading disclosure button expands/collapses children; leaf rows reserve the same disclosure space. Favorite stars keep their meaning.
- Deleting a parent deletes only that Contacts group. Its children become visible at top level, retaining their own descendants. Never cascade-delete groups or contacts.
- Favorites remain independent shortcuts in their existing order. Version one reuses the sidebar's visual conventions, but does not turn the Favorites list/sidebar into a second group-tree editor or automatically favorite ancestors. Show a path where needed to distinguish identically named groups.

## Current implementation and reuse points

1. `ContactGroup` contains a device-local Contacts identifier and name. `GroupIdentity` supplies a durable UUID, normalized name, membership hints, and per-device local-ID pins. These are currently described and used as favorite identities.[^1][^2]
2. `GuessWhoSync+Groups` stores identity JSON in the fixed `groupIdentity` cell. `writeGroupIdentity` copies the existing envelope's raw fields and replaces that cell, preserving unrelated cells. A parent inside the identity JSON would be rewritten with identity metadata; a neighboring cell isolates the two writes.[^3]
3. Repository group operations use a serialized mutation queue. Identity refresh currently visits only favorited identities; resolution falls back to name and membership hints and resolves tied candidates by local ID. Multiple durable identities can therefore resolve to one local group, and the reverse cache holds only one UUID. These are constraints to address before hierarchy writes.[^4]
4. `GroupsListViewController` is a single-section table used by Catalyst and the iPhone shell. Its snapshots use local IDs, its rendered-state cache compares names, and it has no drag/drop delegates. Keep that table and flatten a pure tree projection into visible rows.[^5]
5. `SidebarFavoriteHierarchy` demonstrates separating hierarchy calculations from UIKit. It models a bounded organization/department relationship, so reuse the approach rather than treating it as an arbitrary-depth group model. `SidebarExpansionSetting` demonstrates device-local collapsed-state persistence.[^6][^7]
6. Sidecars merge raw cells by `modifiedAt`, then `modifiedBy`, and preserve unknown inner payloads. The repository's watcher-driven refresh is explicitly read-only; a `.group` change currently triggers a full sidecar projection refresh. The hierarchy needs explicit integration with that refresh, not just an additional UI observer.[^8][^9][^10]
7. The CLI already exposes group creation, renaming, deletion, membership, and favorite commands. New hierarchy commands should follow that transport pattern.[^11]

## Storage and identity

### Parent cell

Add a well-known `groupParent` cell alongside `groupIdentity` in the child's `.group` envelope. Proposed decoded model: `GroupParentAssignment(childIdentityID, parentIdentityID?, modifiedAt, modifiedBy)`. The child ID comes from the envelope key; the parent is a canonical lowercase durable UUID, never a `CNGroup.identifier` or display name.

Use the existing inner-value envelope convention with a small versioned JSON payload containing `parentIdentityID`. A move to top level writes an explicit null assignment with a fresh cell timestamp. Absence also reads as root for legacy records; a tombstoned parent cell reads as root. Do not remove the dictionary entry to clear a parent: older synced assignments must lose to the newer clear under LWW.

Read/modify/write under `withKeyLocked`, preserving other raw fields. Treat an equal desired parent as a no-op unless explicitly clearing a suppressed edge. Identity refresh, rename, starring, and membership never restamp the parent.

Parent writers use persisted millisecond precision: choose `max(current time rounded to milliseconds, greatest observed alias timestamp + 1 millisecond)`, round-trip through `SidecarISO8601`, and verify it remains greater than the observed maximum before saving. Reject unrepresentable/overflowing timestamps rather than wrapping. This advances beyond a future-dated assignment too; its consequence for “oldest” is documented below. Retries of one logical write reuse the same stamped cell.

For new parent cells only, use a writer token `deviceID/operationUUID` in `modifiedBy`, with a fresh UUID per logical write; read both plain legacy device IDs and these opaque tokens. This gives concurrent writers on one device distinct tie-breakers even when neither observed the other's same-millisecond write. It does not alter device identity or binding keys, which use `sync.deviceID`, or any other cell type. All parent mutations, including cleanup/root clears, use this writer. Existing merge compares this string lexically; no general merge change is needed.[^8] Byte-identical retry cells may tie harmlessly. Distinct payloads bearing the exact same token and timestamp are malformed/protocol-violating input, outside the valid-writer convergence claim; do not claim the existing merge repairs them.

Test two opposite merge orders after real encode/decode for successive same-millisecond moves, concurrent same-device writers, distinct devices, retries, clock rollback, and a future-dated observed alias. Collision-free operation UUIDs follow the existing UUID identity assumption.

No schema-version bump or direct edits to resolved package files are required. Older versions ignore the neighboring cell and preserve it through identity writes; prove this using an old-reader/writer fixture. This guarantee does not justify adding a parent property to the decoded/re-encoded `GroupIdentity` JSON.

Malformed parent payloads are ignored for display and preserved raw. Surface diagnostics without deleting data. Parent sidecars that are known but not downloaded are an incomplete snapshot, not proof of removal.

### Generalize favorite-only identities

Extract an internal `ensureGroupIdentity(for:)` operation from favorite minting. Run it inside group mutation serialization and read all locally discoverable identities before reuse/mint decisions. A successful scan means only that locally enumerated files were readable; it cannot prove another device has not minted an undiscovered identity. Permit duplicate mints and handle them safely on discovery. A move ensures identities for both endpoints without favoriting them; untouched top-level groups need not mint.

Resolve identities participating in parent assignments, referenced ancestors, and favorites, including unfavorited parents. Keep an index so rendering does not enumerate sidecars or fetch membership. Rename/membership refresh covers hierarchy identities as well as favorites.

Identity safety is a release gate. Use the following trust contract:

- Add a separate per-device hierarchy-binding cell on each identity, recording the local group ID and provenance: locally minted from an explicit operation on that live group, or explicitly confirmed by the user. Use a key scoped to the device; preserve it as an unknown neighboring cell on older versions. Keep bindings separate from legacy identity JSON and heuristic favorite pins.
- A live, trusted binding can resolve hierarchy. Legacy favorite pins and name/count/hash matches are suggestions only, even for a sole candidate: they cannot distinguish delete/recreate or a historical tie-break. A missing bound local ID invalidates that binding for display until confirmation. Do not automatically rebind it to a same-name group. Local identifiers remain transient internal handles, never graph endpoints.
- Add a “Resolve Group” step to the move picker/status action: show the unavailable group's stored name and known ancestry, let the user choose a current Contacts group, and explicitly confirm “Use \[current group\] for \[stored group\] on this device.” Offer leave-unresolved/cancel; never expose UUIDs or storage vocabulary. Save only the current device's hierarchy binding. Choosing a parent for an ordinary move is not implicit confirmation of an unrelated identity.
- Build alias sets only from trusted bindings to the same current local group. The smallest UUID is the display representative; retain all raw identities. Rank all present parent assignments across aliases, including explicit roots and tombstones, by `(modifiedAt, modifiedBy, childIdentityID)`. Absence has no ranked assignment. Apply the exact selection/suppression pipeline below with no fallback to older aliases. New moves write the representative with a stamp greater than all observed alias assignments.
- An unverified remote identity remains an unavailable node; show locally available groups once at root where necessary. Disable only moves whose required binding/data is unresolved. Give the user the explicit resolution action and retry. On a new device, first adoption can require confirmation; automatic adoption without durable source identity is a deliberate non-goal. Identical records plus identical trusted bindings yield identical trees; different available accounts/bindings need not.
- Replace the one-ID reverse cache with a multimap. For confirmed aliases, a group's star is true if any alias is favorited. Favoriting reuses an already-favorited alias (no new favorite and no reorder); if none exists, reuse the representative. Unfavoriting a live group clears all currently known confirmed-alias favorites, retaining surviving favorite IDs/order elsewhere. Do not auto-collapse duplicate favorite rows: each keeps its existing favorite ID, position, and row-specific remove action. Unverified legacy favorite resolution stays separate and cannot expand hierarchy alias sets. Discovering a previously unseen favorite later may restore the star under existing sync semantics; do not promise global removal of undiscovered IDs.
- Test concurrent minting, unverified legacy pins, duplicate names/empty groups, remote rename before adoption, delete/recreate, removed accounts, duplicate confirmed aliases, any-alias starring/unfavoriting, and partial favorite cleanup. Do not rewrite favorite IDs or garbage-collect identities.

## Cycle prevention and sync convergence

### Local mutations

Expose a repository operation such as `setParent(of:to:)`, accepting live `ContactGroup` values and nil for top level. All UI, CLI, and MCP hierarchy writes use it.

Inside the serialized mutation queue: obtain an authoritative group list and a complete hierarchy snapshot; ensure endpoint identities; revalidate after every suspension and immediately before writing. Reject missing endpoints, self-parenting, and moving under any descendant. Validate using the graph after replacing the child's assignment, not only visible/expanded rows. Serialize create/rename/delete with moves; invalidate stale async projections with a hierarchy generation counter.

Also evaluate the proposed raw assignments and alias projection, including previously suppressed edges: do not accept a locally requested relationship that immediately disappears due to cycle suppression. A nil-parent request is permitted to explicitly clear a suppressed assignment. An unchanged valid parent is a successful no-op. Surface a useful error when storage or required identity data is unavailable; never present an unsaved move as successful.

Single-key locking cannot make a multi-file graph transaction across devices. Local validation prevents mistakes from this device; the deterministic projection below is still required.

### Remote cycles: suppress the oldest connection

Build a pure, iterative `GroupHierarchy` projection in the sync package. Input includes all readable parent cells and their stamps, identity availability, and resolution data. Output includes effective parents, roots, children, depths, paths, and suppressed/unavailable-edge diagnostics.

1. Normalize every present valid parent cell into either a parent assignment or a stamped root (explicit null or tombstone). Absence contributes no assignment. Unknown/malformed payloads remain raw and unavailable. Before any suppression, select and freeze the highest-ranked present assignment for each trusted alias set; singleton identities are sets of one.
2. Independently find cycles in the raw UUID graph, including unresolved nodes with readable assignments. For each cycle mark exactly the edge with the smallest tuple `(modifiedAt, modifiedBy, childIdentityID, parentIdentityID)` as suppressed. A self-loop suppresses itself. Do not suppress an off-cycle edge elsewhere in the component.
3. Build the alias-projected graph from the frozen winners. A winning root, or a winning edge marked suppressed in step 2, leaves its representative at root; never fall back to an older alias assignment. Map remaining endpoints to representatives and detect cycles again, suppressing each cycle's oldest winning edge by the same tuple. Retain the original raw child/parent IDs for ranking. Do not rerun alias selection after suppression.
4. For display, omit unavailable nodes and place a locally available child whose effective parent is unavailable at root, retaining its available subtree. Each live group appears once, including groups with no sidecars. Missing nodes or untrusted bindings do not erase assignments.
5. Sort siblings and flatten visible rows iteratively. Cache adjacency/parent pointers; compute full paths on demand so a deep chain does not eagerly allocate quadratic path data.

Required ordering fixtures: a newer alias tombstone beats an older parent; a selected edge suppressed in the raw graph leaves root despite an older alternative alias edge; alias contraction creates a self-loop or multi-node cycle absent from the raw graph; an absent alias never outranks a present root or parent.

Example: A → B was written Monday and B → A Tuesday. Ignore A → B, so A is root and B is its child. All peers seeing those same assignments suppress the same edge. Timestamp ties use the tuple above. “Oldest” means the stored assignment timestamp; device clock skew means it is not guaranteed to reflect real-world action order.

Suppression is a derived result, never a timestamped repair write. Persisting a fresh root assignment on every observer can race with a legitimate move and create write loops. Keep reads read-only and report the conflict in diagnostics. An affected group's menu can say “A conflicting move was resolved” and allow “Move to Top Level” to explicitly clear its stored parent.

Tradeoff: a suppressed edge can become effective again if another cycle edge is later removed. Document and test that behavior. Permanent removal would need an additional convergent repair/tombstone protocol; defer that rather than pretending an automatic fresh-timestamp delete is safe. Standard same-child concurrent assignments retain existing LWW behavior; adding a global clock or changing general sidecar merge is outside this feature.

## Refresh, deletion, and failure handling

- Publish an immutable hierarchy snapshot/revision through `ContactsRepository`. Recompute after group loading, local hierarchy writes, rename/delete, and `.group`/coarse watcher deliveries. Integrate generations and reload notifications; hierarchy-only refresh is presentation-only, without a full contact refetch or photo invalidation.
- Split read-only binding/projection from pin/fingerprint persistence. Watchers never write; explicit load/mutation paths may persist idempotently.
- “Complete snapshot” means complete for the current locally discoverable corpus, never globally complete across iCloud. On a known read/download failure retain the last good hierarchy intersected with current live groups, expose retry, and block dependent mutations. Without a cached snapshot show a flat provisional list. Undiscovered remote records enter normal projection when they arrive.
- Before explicit deletion capture the parent's trusted alias IDs, favorite IDs, and ALL locally discoverable raw inbound assignments to any deleted-parent alias, including suppressed/non-winning cells. Delete the Contacts group, never its children or contacts. Group affected children by trusted aliases. Under serialization, re-read each child set: if its newest raw assignment still targets a deleted alias, conditionally write a root at its representative newer than every observed alias assignment. If a newer winner already targets another parent or root, preserve that winner; it already dominates older inbound cells. Never stamp a non-winning alias root above a surviving move to another parent. Retain the older cells; the dominating winner prevents their reactivation under the no-fallback projection.
- Integrate hierarchy and favorite cleanup into a structured result: Contacts deletion success plus separate pending cleanup failures. Capture IDs before deletion; retries use them, never name resolution or a second Contacts delete. Clear all known confirmed-alias favorites. Present “Group Deleted” with the failed cleanup categories and retry only pending work. Extend the existing `GroupDeletionOperation` distinction between Contacts failure and favorite cleanup failure, and expose equivalent outcomes to automation.[^12]
- Across-relaunch retry is limited to failures that were successfully recorded: persist captured IDs/versions and unfinished work when cleanup reports failure, before showing its retry UI. If that persistence also fails, offer in-session retry and say that retry cannot be saved. Version one does not promise crash-atomic deletion/cleanup: a process exit after Contacts deletion but before recording cleanup failure can leave orphan edges/favorites for later explicit cleanup. Missing-parent projection still keeps live children reachable. Test and document this crash window; a pre-delete write-ahead journal and recovery state machine would be a separate durability enhancement, not an implicit guarantee of the retry UI.
- A missing deleted parent makes children roots even when cleanup fails. Do not clear edges merely because an external account/group is absent on one device. Explicit deletion invalidates its trusted bindings; missing external bindings remain unresolved without automatic rebinding. Retain orphan sidecars for explicit reconnection.
- Version checks under key locking protect locally observed changes, not unseen remote moves. A remote move observed before cleanup revalidation survives; an unseen concurrent move can lose to the cleanup root by LWW. Undiscovered inbound edges can arrive later. Do not claim causal delete guarantees. Retry refreshes observations, repeats conditional checks, and never restamps completed cleanup. Test these limits and every partial-failure boundary.

## Groups list interaction

### Rendering and navigation

Add a pure app-level visible-row projection containing local ID, durable representative if present, depth, child count/has-children, expansion state, and optional path/status. Keep local IDs as table diffable identifiers for the current Contacts snapshot. Compare the entire render state, not just `renderedNames`, when reconfiguring existing cells.

Use a leading disclosure button with a generous independent hit target and an adjustable indentation constraint. Follow sidebar chevron/spacing conventions; cap physical indentation after roughly three levels on narrow layouts while preserving logical depth, full-path accessibility labels, and path context for deeper rows. Exact spacing and compact path presentation should be verified on-device before settling.

Store collapsed durable IDs in a separate device-local `GroupExpansionSetting`; default new parents open. Do not sync expansion or reuse the sidebar section preference key. Reveal and expand ancestors before fulfilling `select(groupLocalID:)`; do not cancel the pending selection just because it is initially hidden. Preserve the selected group while moving or renaming it. If the user collapses an ancestor of the selected row, highlight that ancestor while leaving the already-open member view intact.

Keeping UITableView avoids a controller migration but makes indentation, disclosure hit testing, expansion state, and accessibility our responsibility; these are explicit Phase 3 work, not automatic outline behavior. Provide separate navigation and disclosure controls, accessibility custom actions for expand/collapse and move, and an accessibility value describing expanded/collapsed state. VoiceOver exposes group name and path/depth without duplicate announcements. Keyboard users can reach disclosure controls and Move commands without dragging. Reset all indentation, disclosure, status, and accessibility state on cell reuse. Verify Dynamic Type and right-to-left layout.

### Drop contract

Add `UITableViewDragDelegate`/`UITableViewDropDelegate`. Start with one group per drag and a typed, local-only payload containing source controller/session identity, local group ID, and captured hierarchy revision. Resolve current IDs and graph at drop time; never rely on a source index path surviving refresh. Reject external, contact, favorite-reorder, and multiple-item payloads.

| Destination | Result | Feedback |
| --- | --- | --- |
| Center of another group row | Move under that group | Highlight target; “Move into [name]” |
| Dedicated “Top Level” target shown during dragging | Clear parent | Highlight full-width root target |
| Gap between root subtrees, or below final root subtree | Clear parent | Root-aligned marker; “Move to Top Level” |
| Gap inside a visible nested subtree | No drop in version one | No misleading reorder insertion line |
| Self or any descendant, including hidden descendants | Reject | Forbidden proposal |

Define root gaps from subtree boundaries in the visible projection, not adjacent row indices: a gap after a root's expanded last descendant is a root gap; a gap between that root and its first child is not. Empty-space/root-target drops work even when every root is expanded, the list is short, or the source is the only root. Position among siblings is not persisted; make the alphabetical result clear in preview copy, e.g. “Move into Family · sorted by name.”

Dropping on a collapsed parent is valid; expand it after successful persistence so the moved group is visible. Optional hover expansion can follow later. Do not show a successful structural move before the repository write succeeds; retain the current tree during the save, disable repeat moves, and rebuild from committed state on success. Use an appropriate landing animation only while the source/destination remain valid; cancel cleanly after a refresh, deletion, failure, or abandoned drag. Test UIKit proposal/geometry behavior on Catalyst and iOS rather than relying solely on index-path intent.

Add “Move to…” and “Move to Top Level” to the shared `GroupContextMenu`, usable from all group entry points. The picker lists top level plus valid parents with indented names and full paths; exclude self and descendants using the full graph. This is the guaranteed touch, keyboard, and accessibility alternative to every drag operation. “New Subgroup…” can be a follow-up convenience; the existing plus button continues to create a top-level group.

### Adjacent surfaces and automation

Add path context to Add to Group destinations and contact-detail group labels where duplicate names would otherwise be ambiguous. These controls still change direct membership. Keep favorites order, starring, and group-member navigation unchanged.

Include automation parity last: `groups set-parent GROUP --parent PARENT` / `--top-level` and matching MCP tool use the shared repository validator. Require exactly one destination and existing idempotency conventions. Add a separate hierarchy read command/tool; preserve existing flat list ordering/paging. Return effective parent and unresolved/conflict status.

Keep existing `g-` wire IDs scoped to the current helper/device: they derive from local Contacts group IDs, not the durable hierarchy UUID.[^13] The hierarchy response's `groupId` and nullable `parentGroupId` use those same device-scoped IDs; root versus unavailable parent is distinguished by status. If exposing durable correlation, add explicitly separate `identityId`/`parentIdentityId` fields (nullable for unminted groups), never reinterpret an existing ID. Unknown/unresolved identities can be diagnostic entries with no local wire ID and cannot be selected as move destinations. Cross-device clients must re-list/re-resolve device-scoped IDs. Identity confirmation is initially UI-only; CLI returns an actionable resolution-required error.

Update tool definitions, request/response mapping, dispatcher, CLI help, compatibility handling, and tests together. Old helpers reject unsupported new tools clearly.

## Implementation sequence and acceptance gates

1. **Identity and persistence.** Generalize identity helpers, define strict hierarchy resolution/alias projection, and implement parent-cell reads/writes. Tests prove unfavorited endpoints, duplicate mint handling, incomplete reads, unknown-cell preservation, old-writer compatibility, root clears, and no-op writes. Release gate: demonstrate the identity behavior above with two simulated devices before wiring UI.
2. **Pure forest and repository.** Add iterative graph projection and serialized move validation; integrate refresh and deletion semantics. Permuting record/input order and replaying duplicate notifications must leave identical effective results and cause zero projection writes. Failures cannot publish unsaved parents or wipe the last good snapshot.
3. **Outline and move picker.** Render indented/collapsible rows, preserve selection/expansion, and add accessible shared menu commands. Every group must remain reachable through arbitrary-depth trees, unresolved parents, collapse/reveal, and reload.
4. **Drag/drop.** Implement explicit row/root zones over the same move operation. Verify subtree movement, promotion to root, collapsed targets, invalid cycles, stale sessions, failure, and alphabetical placement on Catalyst and iOS.
5. **Automation and documentation.** Add hierarchy read/write CLI/MCP paths without breaking existing commands. Publish current behavior in `docs/` only after implementation; update favorite-only comments and user help. Explicitly correct the `groupIdentityCellKey` documentation that currently says a group sidecar carries exactly one cell/whole-file LWW: group identity, parent, and binding cells merge independently. Run the independent review cycle on implemented code.

Likely production files: `GuessWhoSync+Groups.swift`, new `GroupHierarchy.swift`/assignment types, `ContactsRepository.swift`, `GroupsListViewController.swift`, new `GroupExpansionSetting.swift` and visible-row/drop helpers, `GroupContextMenu.swift`, group presentation/picker surfaces, and CLI/MCP transport files. Avoid a new dependency or a general tree framework.

## Verification plan

Storage/graph tests cover legacy flat records; root clears winning over stale parents; identity writes preserving parent cells and vice versa; two- and three-node cycles; independent cycles; older off-cycle branches; self-loops; equal timestamps; clock skew; aliases with competing root/parent assignments; unresolved vertices; malformed payloads; and 1,000-node chains. Include a property-style invariant test: every live group appears once, every effective parent chain terminates, and shuffled inputs yield the same forest.

Repository tests cover two individually valid offline moves that form a merged cycle; concurrent same-child moves; suppressed-edge reactivation; explicitly clearing a suppressed edge; rename/membership refresh not changing edge age; unfavorite not losing hierarchy; dropped downloads; watcher zero-write behavior; stale async completion; delete/cleanup races; and permissions/write failures. Reuse the in-memory stores and existing group/favorite/sidecar-refresh suites.

App tests cover pure visible rows and root-gap classification, disclosure vs navigation, hidden programmatic selection, reconfiguration on depth-only changes, move-picker exclusions, and stale payload validation. Manually verify drag/drop animations, pointer targets, VoiceOver, keyboard, Dynamic Type, narrow screens, and RTL. Test that parent email and contact membership never aggregate descendants.

Run targeted new suites first, then `swift test` for the package, app unit tests under an available simulator, and both Catalyst and iOS builds with worktree-local DerivedData. Example Catalyst build: `xcodebuild -project App/GuessWho.xcodeproj -scheme GuessWho -destination 'platform=macOS,variant=Mac Catalyst' -derivedDataPath .build/DerivedData build`. Choose an actually installed simulator for iOS. Report exact commands and distinguish sandbox/service failures from compiler/test failures.

This plan-only change requires citation/path checks and independent review, not compilation. Success for this task is a committed, code-grounded plan approved by one worker reviewer and one sol reviewer after any requested revisions.

## Sources

[^1]: [Current live group representation](../Sources/GuessWhoSync/ContactGroup.swift:ContactGroup)
[^2]: [Durable group identity and membership fingerprint](../Sources/GuessWhoSync/GroupIdentity.swift:GroupIdentity)
[^3]: [Group identity read/write and minting](../Sources/GuessWhoSync/GuessWhoSync+Groups.swift:GuessWhoSync.writeGroupIdentity)
[^4]: [Favorite-only refresh](../Sources/GuessWhoSync/ContactsRepository.swift:ContactsRepository.refreshAllGroupIdentities), [mutation serialization](../Sources/GuessWhoSync/ContactsRepository.swift:ContactsRepository.performSerializedGroupMutation), [identity resolver](../Sources/GuessWhoSync/ContactsRepository.swift:ContactsRepository.resolveGroupIdentity), and [single-ID reverse cache update](../Sources/GuessWhoSync/ContactsRepository.swift:ContactsRepository.cache)
[^5]: [Groups table, snapshots, selection, and cells](../App/GuessWho/GroupsListViewController.swift:GroupsListViewController)
[^6]: [Existing pure sidebar hierarchy projection](../App/GuessWho/SidebarFavoriteHierarchy.swift:SidebarFavoriteHierarchy)
[^7]: [Device-local sidebar expansion persistence](../App/GuessWho/SidebarExpansionSetting.swift:SidebarExpansionSetting)
[^8]: [Whole-cell sidecar merge and tie break](../Sources/GuessWhoSync/SidecarMerge.swift:merge)
[^9]: [Sidecar compatibility contract](../docs/sidecar-compatibility.md)
[^10]: [Read-only sidecar refresh and group change handling](../Sources/GuessWhoSync/ContactsRepository.swift:ContactsRepository.refreshFromSidecarChange)
[^11]: [Existing group CLI command surface](../Sources/GuessWhoCLICore/GroupsCommand.swift:GroupsCommand)
[^12]: [Separate favorite cleanup after Contacts deletion](../App/GuessWho/GroupContextMenu.swift:GroupDeletionOperation)
[^13]: [Group wire IDs derived from local Contacts identifiers](../Sources/GuessWhoMCPCore/WireRecordID.swift:WireRecordID.groupID)
