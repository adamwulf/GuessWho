# Nested groups implementation plan

Status: proposed; implementation is not part of this change.
Date: 2026-09-16.

## Recommendation

Represent organization as a forest: each group has zero or one parent. Store a separate parent cell on the existing durable group identity sidecar. Prevent cycles in local commands and deterministically suppress the oldest edge of any cycle introduced through sync. Do not write automatic cycle repairs.

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

Read/modify/write under `withKeyLocked`, preserving every other raw field. Treat an already-equal desired parent as a no-op, including a redundant root assignment, unless the user is explicitly clearing a suppressed stored edge. Rename, favorite changes, device pinning, and membership fingerprint refresh must never restamp the parent cell. Its `modifiedAt` represents the last parent assignment, not group creation time.

No schema-version bump or direct edits to resolved package files are required. Older versions ignore the neighboring cell and preserve it through identity writes; prove this using an old-reader/writer fixture. This guarantee does not justify adding a parent property to the decoded/re-encoded `GroupIdentity` JSON.

Malformed parent payloads are ignored for display and preserved raw. Surface diagnostics without deleting data. Parent sidecars that are known but not downloaded are an incomplete snapshot, not proof of removal.

### Generalize favorite-only identities

Extract an internal `ensureGroupIdentity(for:)` operation from favorite minting. It runs inside the existing mutation serialization, first tries existing identities, then mints only when no matching identity exists and the identity scan is complete. A move ensures identities for both endpoints; this must not favorite either group. New top-level groups need not eagerly mint identities.

Resolve all identities participating in stored parent assignments, all referenced ancestors, and favorites, including unfavorited parents with no parent cell themselves. Keep an index of these participants so render passes do not enumerate sidecars or fetch group members. Renames and membership changes refresh metadata for hierarchy identities as well as favorites.

Identity safety is a release gate, not an assumption that the current favorite resolver is sufficient:

- Preserve a valid device pin. Without a pin, require an unambiguous candidate for hierarchy resolution. An equal name/count/hash score must remain unresolved instead of choosing the lowest local ID. Empty fingerprints are weak evidence. Existing favorite behavior can remain separately compatible, but it must not silently authorize a hierarchy write.
- Concurrent first-use on two devices can mint duplicate UUIDs. Do not automatically merge identities solely because their names or fingerprints match. Build a per-device alias set only where identities have confirmed pins to the same live local group. Choose the smallest UUID as that set's display representative; retain all raw identities and their edges.
- For a confirmed alias set, choose the newest parent assignment across its members by `(modifiedAt, modifiedBy, childIdentityID)`; include explicit-root assignments in this choice. Map both endpoints to their display representatives, then run cycle detection again on this projected graph. This prevents duplicate aliases from producing duplicate rows, multiple parents, or a local self-cycle. A new move writes to the representative with a stamp later than all known assignments in that alias set.
- Alias grouping is a local interpretation of confirmed mappings, not a new global identity merge protocol. Two devices with different available groups can show different incomplete trees; identical records plus identical resolutions must yield identical trees. If safe mapping cannot be established, show affected live groups at root, mark their organization as unavailable, and disable dependent moves. Provide a retry and a parent picker that can explicitly establish the local mapping; never guess or erase synced edges to make the tree look complete.
- Test concurrent minting, duplicate names, empty groups, rename on another device before first adoption, removed accounts, and duplicate pinned identities. Do not broaden this work into rewriting favorite IDs or deleting alias records.

## Cycle prevention and sync convergence

### Local mutations

Expose a repository operation such as `setParent(of:to:)`, accepting live `ContactGroup` values and nil for top level. All UI, CLI, and MCP hierarchy writes use it.

Inside the serialized mutation queue: obtain an authoritative group list and a complete hierarchy snapshot; ensure endpoint identities; revalidate after every suspension and immediately before writing. Reject missing endpoints, self-parenting, and moving under any descendant. Validate using the graph after replacing the child's assignment, not only visible/expanded rows. Serialize create/rename/delete with moves; invalidate stale async projections with a hierarchy generation counter.

Also evaluate the proposed raw assignments and alias projection, including previously suppressed edges: do not accept a locally requested relationship that immediately disappears due to cycle suppression. A nil-parent request is permitted to explicitly clear a suppressed assignment. An unchanged valid parent is a successful no-op. Surface a useful error when storage or required identity data is unavailable; never present an unsaved move as successful.

Single-key locking cannot make a multi-file graph transaction across devices. Local validation prevents mistakes from this device; the deterministic projection below is still required.

### Remote cycles: suppress the oldest connection

Build a pure, iterative `GroupHierarchy` projection in the sync package. Input includes all readable parent cells and their stamps, identity availability, and resolution data. Output includes effective parents, roots, children, depths, paths, and suppressed/unavailable-edge diagnostics.

1. Decode valid assignments; explicit roots have no outgoing edge. Include edges through temporarily unresolved identities in raw-graph cycle analysis, even if they have no local row.
2. Find cycles in the functional graph (at most one parent per child). For each cycle suppress exactly the edge with the smallest tuple `(modifiedAt, modifiedBy, childIdentityID, parentIdentityID)`. A self-loop suppresses itself. Do not suppress the oldest edge elsewhere in the component or in a descendant branch.
3. Project confirmed aliases and select their assignments as described above, then apply the same deterministic rule to any additional cycles caused by alias contraction. Ensure raw-cycle-suppressed assignments are not accidentally reinstated during alias selection; select winners from raw assignments first, then apply both suppression sets to that fixed selection.
4. For display, omit unavailable nodes and put a locally available child whose effective parent is unavailable at root. Retain that child's available subtree. Never hide it or attach it by matching names. Each live group appears exactly once, including groups without sidecars.
5. Sort siblings and flatten visible rows with an explicit stack. Cache ancestry/path information; avoid recursive traversal and repeated membership fetches.

Example: A → B was written Monday and B → A Tuesday. Ignore A → B, so A is root and B is its child. All peers seeing those same assignments suppress the same edge. Timestamp ties use the tuple above. “Oldest” means the stored assignment timestamp; device clock skew means it is not guaranteed to reflect real-world action order.

Suppression is a derived result, never a timestamped repair write. Persisting a fresh root assignment on every observer can race with a legitimate move and create write loops. Keep reads read-only and report the conflict in diagnostics. An affected group's menu can say “A conflicting move was resolved” and allow “Move to Top Level” to explicitly clear its stored parent.

Tradeoff: a suppressed edge can become effective again if another cycle edge is later removed. Document and test that behavior. Permanent removal would need an additional convergent repair/tombstone protocol; defer that rather than pretending an automatic fresh-timestamp delete is safe. Standard same-child concurrent assignments retain existing LWW behavior; adding a global clock or changing general sidecar merge is outside this feature.

## Refresh, deletion, and failure handling

- Publish a complete immutable hierarchy snapshot and revision through `ContactsRepository`. Recompute after group loading, local hierarchy writes, relevant rename/delete events, and `.group`/coarse sidecar watcher deliveries. Integrate with existing generations and reload notifications; hierarchy-only refresh must be presentation-only and must not refetch all contacts or invalidate photo caches.
- Split read-only identity resolution/projection from pin/fingerprint persistence so watcher refresh cannot call a helper that writes. Persist adoption only from explicit load/mutation paths with idempotent writes.
- On temporary read/download failure keep the last good hierarchy where its live groups still exist, expose an unavailable/retry state, and disable mutations needing incomplete data. A fresh installation with no cached hierarchy can show a flat provisional list. Never publish a partial read as an authoritative empty graph.
- Explicit parent deletion: identify direct effective children before deletion, delete the Contacts group, then clear those children's parent assignments best-effort. Their descendants are untouched. If cleanup fails, the missing-parent projection still makes the children roots; report “Group deleted; some organization changes could not be saved” with a retry. Do not tell the user the group deletion failed after it succeeded.
- Do not garbage-collect or auto-clear edges merely because an external group/account disappeared on one device. Another device may still resolve it, or Contacts/iCloud may be temporarily unavailable. Keep orphan sidecars for reconnection. A same-name recreated group is not automatically proof of identity; apply the stricter resolver.
- Before clearing any child's parent after deletion, re-read and require that its assignment still targets the deleted parent and matches the captured assignment version. A concurrent move must survive cleanup. No cross-file atomicity is claimed; test each failure boundary.

## Groups list interaction

### Rendering and navigation

Add a pure app-level visible-row projection containing local ID, durable representative if present, depth, child count/has-children, expansion state, and optional path/status. Keep local IDs as table diffable identifiers for the current Contacts snapshot. Compare the entire render state, not just `renderedNames`, when reconfiguring existing cells.

Use a leading disclosure button with a generous independent hit target and an adjustable indentation constraint. Follow sidebar chevron/spacing conventions; cap physical indentation after roughly three levels on narrow layouts while preserving logical depth, full-path accessibility labels, and path context for deeper rows. Exact spacing and compact path presentation should be verified on-device before settling.

Store collapsed durable IDs in a separate device-local `GroupExpansionSetting`; default new parents open. Do not sync expansion or reuse the sidebar section preference key. Reveal and expand ancestors before fulfilling `select(groupLocalID:)`; do not cancel the pending selection just because it is initially hidden. Preserve the selected group while moving or renaming it. If the user collapses an ancestor of the selected row, highlight that ancestor while leaving the already-open member view intact.

VoiceOver exposes group name, path/depth, and expanded/collapsed state. Provide expand/collapse and move actions; keyboard users can reach disclosure controls and Move commands without dragging. Reset all indentation, disclosure, status, and accessibility state on cell reuse. Verify Dynamic Type and right-to-left layout.

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

Include basic automation parity as the last implementation phase: add a desired-state `groups set-parent GROUP --parent PARENT` / `--top-level` command and matching MCP tool, routed through the repository validator. Require exactly one destination, use existing idempotency conventions, and return effective state or a typed error. Add a separate hierarchy read command/tool with stable group wire IDs, parent IDs, and unresolved/conflict status so callers do not need to infer the tree from flat membership results. Preserve existing group wire IDs, list ordering, and paging contracts; do not substitute durable hierarchy UUIDs for already-issued wire IDs. Update tool definitions, request/response mapping, dispatcher, CLI help, protocol compatibility handling, and their tests together. Old helpers must reject unsupported new tools clearly.

## Implementation sequence and acceptance gates

1. **Identity and persistence.** Generalize identity helpers, define strict hierarchy resolution/alias projection, and implement parent-cell reads/writes. Tests prove unfavorited endpoints, duplicate mint handling, incomplete reads, unknown-cell preservation, old-writer compatibility, root clears, and no-op writes. Release gate: demonstrate the identity behavior above with two simulated devices before wiring UI.
2. **Pure forest and repository.** Add iterative graph projection and serialized move validation; integrate refresh and deletion semantics. Permuting record/input order and replaying duplicate notifications must leave identical effective results and cause zero projection writes. Failures cannot publish unsaved parents or wipe the last good snapshot.
3. **Outline and move picker.** Render indented/collapsible rows, preserve selection/expansion, and add accessible shared menu commands. Every group must remain reachable through arbitrary-depth trees, unresolved parents, collapse/reveal, and reload.
4. **Drag/drop.** Implement explicit row/root zones over the same move operation. Verify subtree movement, promotion to root, collapsed targets, invalid cycles, stale sessions, failure, and alphabetical placement on Catalyst and iOS.
5. **Automation and documentation.** Add hierarchy read/write CLI/MCP paths without breaking existing commands. Publish current behavior in `docs/` only after implementation; update favorite-only comments and user help. Run the independent review cycle on implemented code.

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
[^4]: [Repository group serialization, identity resolution, and favorite-only refresh](../Sources/GuessWhoSync/ContactsRepository.swift:ContactsRepository.refreshAllGroupIdentities)
[^5]: [Groups table, snapshots, selection, and cells](../App/GuessWho/GroupsListViewController.swift:GroupsListViewController)
[^6]: [Existing pure sidebar hierarchy projection](../App/GuessWho/SidebarFavoriteHierarchy.swift:SidebarFavoriteHierarchy)
[^7]: [Device-local sidebar expansion persistence](../App/GuessWho/SidebarExpansionSetting.swift:SidebarExpansionSetting)
[^8]: [Whole-cell sidecar merge and tie break](../Sources/GuessWhoSync/SidecarMerge.swift:merge)
[^9]: [Sidecar compatibility contract](../docs/sidecar-compatibility.md)
[^10]: [Read-only sidecar refresh and group change handling](../Sources/GuessWhoSync/ContactsRepository.swift:ContactsRepository.refreshFromSidecarChange)
[^11]: [Existing group CLI command surface](../Sources/GuessWhoCLICore/GroupsCommand.swift:GroupsCommand)
