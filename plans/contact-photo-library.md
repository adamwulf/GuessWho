# Multiple photos on a contact

A contact can hold many photos, and one of them is current.

## What Adam asked for (2026-10-31)

1. See all photos, both current and previous.
2. Add new photos and remove old ones.
3. Changing a photo always keeps the previous one on the contact.
4. Swap which photo is current by choosing one already on the contact, in addition
   to the existing ways to add one.

## Product decisions

- **Contacts holds only the current photo.** Contacts.app and everything else that
  reads Contacts see just that one.
- **Remove Photo keeps the photo.** It stops using the photo as current, per rule 3,
  and the photo stays in All Photos. The contact then shows no photo. Only Delete
  in All Photos removes a photo for good, with a confirmation, on every device.
- **Adding from All Photos doesn't change the current photo**, unless the contact
  has none. Choose Photo in the existing menu still adds and makes current.
- **Each photo keeps its own crop.** Swapping back restores that photo's crop.
- **The same image is never stored twice.** Re-importing a LinkedIn photo or choosing
  the same file reuses the existing photo. Identity is the bytes' SHA-256.
- **No limit** on the number of photos.
- **Deleting the current photo** clears it from Contacts too, and no other photo
  becomes current on its own. The user chooses.
- **An older encrypted photo this device can't read** shows as a placeholder with no
  actions, because another device may still read it.
- **CLI/MCP gets no new tools.** `contacts_set_photo` keeps the previous photo like
  any other change, and `contacts_delete_photo` behaves like Remove Photo. Update
  their descriptions and docs to say so.

No plain-language UI text may use "sidecar", "blob", "library", or "cell". Say "photos".

## Storage

A photo is a `.dat` file plus a pointer, as today.

- **Library cell.** Every stored photo has one `.blob` cell, field name `contactPhoto`
  (`ContactsRepository.contactPhotoFieldName`), whose cell key is the blobId's UUID
  uppercased. One blob, one key, so two devices adding the same blob converge. It is
  written once, and later only for crop or digest updates or to delete.
- **`profilePhoto` stays** as the fixed cell naming the current photo. It holds a copy
  of the current photo's pointer. Nothing about that cell's shape changes, so
  `profilePhoto(at:)`, `ContactPhotoSourceTracker`, and `loadedPhotoPointers` keep
  working.
- **`previousPhoto` is read, never written again.** An existing live one is just
  another photo on the contact.
- **The photos on a contact** are the union of all live `.blob` cells named
  `profilePhoto`, `previousPhoto`, or `contactPhoto`, deduplicated by blobId.

Why not move pointers between cells: envelope merge is whole-cell last-writer-wins.
If two devices each moved pointers at once, one pointer could be overwritten by the
other and that photo lost. With an add-only cell per photo, a race over which photo is
current can't lose one. No migration is needed. Races with a delete or a crop have other
outcomes, listed under "What races do" in `docs/profile-photos.md`. One can't be prevented
with this design: a crop stamped later than a delete on another device wins the cell, so
the photo comes back with its file gone, as a placeholder that deleting again clears.

### Identity merges

A `.dat` file's name includes its contact's key. Case D (`handleCaseD`) merged the
loser's cells into the winner and then deleted the loser, which deleted the loser's
files, so the winner kept cells naming files that no longer existed. The loss is real
but narrow: the only production route to a merge is `resolveOrMintGuessWhoID` ->
`reconcileContactIdentity(localID:)`, reached when a write's `ContactID` has no
GuessWho ID. `reconcileContactIdentities()` has no production caller, and this work
adds none.

- Before deleting a loser, the merge moves each of its files to the winner with
  `moveBlob(blobId:from:to:)`: a rename on disk, so an older encrypted file moves
  without being opened.
- **Placeholder rule.** An iCloud placeholder is never renamed, because its format is
  private to the system. A loser file that exists only as a placeholder is treated like
  an envelope that hasn't downloaded: its download starts, and the merge stops before any
  write. Nothing is destroyed. A later attempt usually doesn't come: the merge runs only
  while the cached contact has no GuessWho ID, so after a reload the fast path skips it
  and the loser stays, with its photos and notes out of view. This work adds no new trigger.
- If a move or the winner's write fails after files moved, they go back, best-effort and
  logged. After a timed-out winner write they stay, because that write can still land.
- Each side's live `profilePhoto` gets a library cell before merging. Both identities use
  the fixed cell, so one pointer loses, and with older data nothing else names that file.

### Rules for every write

All under `withKeyLocked`, in one envelope write. Order: `.dat` first, then envelope,
as `setBlobField` does today.

- **Never delete on overwrite for these three field names.** Writing `profilePhoto`
  must not delete the superseded `.dat`. Before repointing, if the superseded pointer
  has no live library cell, add one. `setBlobField`'s delete-on-overwrite goes away for
  these fields.
- **Any new photo gets its library cell and its `profilePhoto` update in the same
  envelope write**, so a racing device can't lose it.
- **A library cell's `createdAt`** is when the photo was added. The `profilePhoto` slot
  keeps the `createdAt` of the contact's first photo across repoints, so a superseded
  pointer's new library cell takes that slot's `modifiedAt`, and the list does the same
  for a pointer with no library cell yet.
- **A library tombstone stays.** A superseded pointer whose library key holds a tombstone
  gets no new cell: that photo was deleted on another device. A superseded pointer's new
  cell takes the pointer's own older stamp, so a delete this device hasn't seen beats it.
- **A library tombstone means deleted.** Delete writes one at the library key even with no
  cell there. A `profilePhoto` naming a photo whose library key is tombstoned isn't a stored
  current photo, and that photo isn't listed.

### Operations

**`setContactPhoto(for:imageData:crop:)`** keeps its signature and callers.
- Non-nil image:
  1. If what's showing is a Contacts photo with no stored original, or an external
     Contacts change overrode the stored one (`usesSystemPhoto`), store those Contacts
     bytes as a photo first (deduplicated). Replaces `snapshotCurrentPhotoIfPresent`,
     and this stays best-effort. If the change then fails and Contacts ends up holding
     those bytes again, this store is undone, so a failed write leaves storage as it was.
     The undo leaves one tombstoned cell, which nothing shows. If restoring Contacts
     fails too, the stored copy stays, because it's the only one left. A current photo
     this device can't read gets no Contacts copy: a stored original exists, and it
     stays on the contact.
  2. SHA-256 the incoming bytes and compare against the readable photos on the contact.
     On a match, reuse that photo, with `crop ?? its existing crop`. Otherwise store new.
     Only a photo with the same `byteCount` is read and hashed.
  3. If the match is already current, the crop is unchanged, and Contacts' digest matches
     the pointer's `systemPhotoDigest`, return without writing to Contacts. This stops a
     repeated LinkedIn import from churning, and choosing the photo again heals Contacts
     that drifted. The group holding `profilePhoto` is checked first, so a duplicate in
     older data can't take current off the cropped photo.
  4. Write Contacts, then commit, restoring Contacts on failure, as today.
- Nil image: as step 1, then clear Contacts and tombstone `profilePhoto`. Library
  cells stay. `removeProfilePhoto` keeps its current meaning, and a pointer with no
  library cell gets one in the same write.

Dedup covers new writes. Existing data can hold the same bytes under two blobIds, from
an old repeat import, and the list can't see that without reading bytes, so both show.
Two devices adding the same image at the same moment also mint two photos.

**`setContactPhotoCrop`** no longer writes a new `.dat` for a stored photo. It updates
the pointer's crop in `profilePhoto` and in that photo's library cell, keeping the
`.matching(blobID)` check. Two cases write bytes, as today: a first crop of a
Contacts-only photo, and adopting an external Contacts change. The stored original
in the second case stays as a library photo. The `storedFileUnreadable` refusal stays.

**New: list.** `contactPhotos(for: ContactID) async throws -> [ContactPhotoItem]`,
newest first by the cell's `createdAt`, with the current one marked. Add a Contacts-only
item when Contacts has a photo that no stored photo stands for: no stored current, or
`usesSystemPhoto`. Reads pointers only, with one exception: spotting an external Contacts
change needs the current photo's digest, so the list reads that one file and the Contacts
image. No other photo's bytes are read.

**New: bytes.** `contactPhotoData(for: ContactID, photoID:) async throws -> ContactPhoto?`.
A pending `.dat` returns nil and starts its download, and the item shows a placeholder
until reload. An unreadable older file throws `storedPhotoUnreadable` and marks the item
unavailable. Only a read can detect that, so `isAvailable` stays true until one fails, and
the mark lives in memory. The grid reads every photo, so it flips right away.

A current photo whose file is truly missing, with no placeholder, shows the Contacts copy
instead of a blank avatar, and changing or cropping it keeps that copy. A real placeholder
stays pending. `loadedPhotoPointers` holds the pointer and `modifiedAt` a consumer last
loaded, and only a read a consumer will show updates it: the list and pre-write reads don't.

**New: add.** `addContactPhoto(for:imageData:crop:) async throws`. Stores it
(deduplicated). If the contact has no current photo, it also becomes current,
through the same path as `setContactPhoto`.

**New: swap.** `setCurrentContactPhoto(for:photoID:) async throws`. Reads the chosen
bytes, applies step 1, writes them to Contacts, then repoints `profilePhoto` at that
photo with its crop and a fresh `systemPhotoDigest`, then updates `photoSources`.
Restores Contacts on failure. Refuses a photo whose file is pending or unreadable.

**New: delete.** `deleteContactPhoto(for:photoID:) async throws`. Tombstones every live
cell naming that blobId, then deletes the `.dat`. If it was current, also clear
Contacts first, restoring on failure. The Contacts-only item clears Contacts. This is
now the immediate delete from the sweep discussion, so a deleted photo doesn't linger
in iCloud. `sweepOrphanBlobs` stays uncalled. It refuses an older file this device can't
read, since another device may still read it.

What it does depends on the file. All of this is checked before any write:
- **Present:** deleted, as above.
- **Only an iCloud placeholder on this device:** a placeholder can't be removed, so the
  file would stay in iCloud. The delete starts its download, throws `photoPending`, and
  changes nothing, including Contacts when the photo is current.
- **Truly missing, with no placeholder** (an older build deleted it, or a dangling
  pointer): the delete tombstones the cells, so a stuck placeholder can always be cleared.

All of these post the same refresh `setContactPhoto` does. A failed Contacts write
leaves storage unchanged. `sync == nil`: the list shows only the Contacts photo, and
add, swap, and delete of stored photos throw `SidecarUnavailableError`.

`ContactPhotoItem` is public and opaque: `id` (a `String`; a blobId, or a fixed value
for the Contacts-only item), `isCurrent`, `crop`, `addedAt` (nil for the Contacts-only
item), and `isAvailable`.

**`ContactPhotoSourceTracker`** needs one change after all. It cleared an override only
when the blobId changed, and choosing a photo again reuses its blobId. So if Contacts.app
changed a photo and one device picked the old photo again, another device stayed on the
uncropped Contacts copy indefinitely. It now takes a revision: the blobId plus the
`profilePhoto` cell's `modifiedAt`. The revision lives in local preferences only, and the
synced cell doesn't change.

Add `contactPhotoFieldName` to `reservedFieldNames`. `.blob` cells are already hidden
from custom fields. Check every other walker of `.blob` cells.

## UI

New `App/GuessWho/ContactPhotosView.swift`, presented as a sheet, shared by iPhone,
iPad, and Catalyst.

- A grid of photos, newest first, each rendered with its crop through the existing
  rendering helper, off the main thread, bounded to 600 pixels. A tile can be about 540
  pixels wide on a 3x iPhone, where 256 looks soft.
- The current photo has a visible "Current" label. Placeholders for pending and
  unavailable photos. A photo with no bytes here reads "Not available right now", because
  its file may be gone rather than downloading, and a read error has its own wording.
- The Mac file panel is modeless, so Done, Add Photo, and the contact card's Choose Photo
  and All Photos are disabled while it's open.
- Each photo opens a menu: View Photo (the existing `ContactPhotoViewer`), Use as
  Current Photo (hidden on the current one), Delete Photo (destructive, with a
  confirmation saying it's removed from all the user's devices, and that the contact
  will have no photo if it's current). A photo still downloading has no bytes to view
  or choose, so its menu offers only Delete Photo. The view can't tell a file on its way
  from one that's gone until it tries: the first reports it's still downloading and to
  try again shortly, and the second is cleared.
- Toolbar: Done and Add Photo. Add Photo reuses the existing pickers and the crop
  editor, then calls `addContactPhoto`. `PhotoChangeModifier` moved to its own file, with
  the shared picked-image decoding, so both views can use it.
- Empty state when there are no photos, with Add Photo.
- Errors use the existing alert style, and every failure logs with `error.logContext()`,
  or `logCodes()` for a file the user chose.
- Reload on `.contactsRepositoryDidReload`, so a photo arriving from another device
  appears. After any change, invalidate `ContactPhotoLoader` and refresh the header,
  as the crop editor's callback does.

Entry points in `ContactDetailView`:
- Edit-mode photo menu: add **All Photos**, always shown, even with no current photo.
- Full-screen viewer from the header (not edit mode): add an **All Photos** button.
  Not shown when the viewer is opened from inside All Photos.

## Docs and tests

- Rewrite the storage and replacement parts of `docs/profile-photos.md`, and add it to
  the docs list in `AGENTS.md`. In particular, replacing a photo no longer deletes an
  older encrypted file: remove that paragraph's claim.
- `docs/sidecar-compatibility.md`: note the new `contactPhoto` cells and that `previousPhoto` is
  no longer written. An older build hides them, since they're `.blob`, and preserves them.
- Update `App`-independent MCP/CLI descriptions for `contacts_delete_photo`.

Package tests, on both the in-memory store and `FileSystemSidecarStore` with
`NoKeyBlobCrypto`:
- Rules 1–4 end to end: replacing keeps the old photo with its crop, adding doesn't
  change current, swapping writes Contacts and restores that photo's crop, deleting
  removes the file and cells.
- Remove Photo keeps the photo. Deleting the current photo clears Contacts.
- A Contacts-only photo is kept on change. An external Contacts change: both kept.
- Dedup: same bytes reused, repeated LinkedIn import adds nothing and writes nothing.
- A crop edit writes no new `.dat`.
- Existing data with no migration: `profilePhoto` alone, and with `previousPhoto`.
- Concurrency: merge two envelopes that each changed current; no photo is lost.
- A failed Contacts write leaves storage unchanged; a failed storage write restores Contacts.
- Unreadable older file: listed unavailable, can't be swapped, and survives replacement.
- `sync == nil` behavior.
- `previousPhoto` is never written. Update the tests that assert it was.

Hand check (needs the app, on iPhone and Mac): every step of Adam's four rules, a
photo syncing between devices, and the Contacts.app view of each change.

## Not included

- CLI/MCP tools to list, swap, or delete individual photos.
- Reordering photos.
- Wiring up `sweepOrphanBlobs`.
- The existing race where a deleted photo's file disappears before the JSON arrives,
  which shows the same retryable state as a pending download.
