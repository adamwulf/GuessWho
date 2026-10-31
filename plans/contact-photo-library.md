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
other and that photo lost. With an add-only cell per photo, the worst a race does is
pick a different current photo. No migration is needed.

### Rules for every write

All under `withKeyLocked`, in one envelope write. Order: `.dat` first, then envelope,
as `setBlobField` does today.

- **Never delete on overwrite for these three field names.** Writing `profilePhoto`
  must not delete the superseded `.dat`. Before repointing, if the superseded pointer
  has no live library cell, add one. `setBlobField`'s delete-on-overwrite goes away for
  these fields.
- **Any new photo gets its library cell and its `profilePhoto` update in the same
  envelope write**, so a racing device can't lose it.

### Operations

**`setContactPhoto(for:imageData:crop:)`** keeps its signature and callers.
- Non-nil image:
  1. If what's showing is a Contacts photo with no stored original, or an external
     Contacts change overrode the stored one (`usesSystemPhoto`), store those Contacts
     bytes as a photo first (deduplicated). Replaces `snapshotCurrentPhotoIfPresent`,
     and this stays best-effort.
  2. SHA-256 the incoming bytes and compare against the readable photos on the contact.
     On a match, reuse that photo, with `crop ?? its existing crop`. Otherwise store new.
  3. If the match is already current and the crop is unchanged, return without writing
     to Contacts. This stops a repeated LinkedIn import from churning.
  4. Write Contacts, then commit, restoring Contacts on failure, as today.
- Nil image: as step 1, then clear Contacts and tombstone `profilePhoto`. Library
  cells stay. `removeProfilePhoto` keeps its current meaning.

**`setContactPhotoCrop`** no longer writes a new `.dat` for a stored photo. It updates
the pointer's crop in `profilePhoto` and in that photo's library cell, keeping the
`.matching(blobID)` check. Two cases write bytes, as today: a first crop of a
Contacts-only photo, and adopting an external Contacts change. The stored original
in the second case stays as a library photo. The `storedFileUnreadable` refusal stays.

**New: list.** `contactPhotos(for: ContactID) async throws -> [ContactPhotoItem]`,
newest first by the cell's `createdAt`, with the current one marked. Add a Contacts-only
item when Contacts has a photo that no stored photo stands for: no stored current, or
`usesSystemPhoto`. Reads pointers only, no image bytes.

**New: bytes.** `contactPhotoData(for: ContactID, photoID:) async throws -> ContactPhoto?`.
A pending `.dat` returns nil and starts its download, and the item shows a placeholder
until reload. An unreadable older file marks the item unavailable.

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
in iCloud. `sweepOrphanBlobs` stays uncalled.

All of these post the same refresh `setContactPhoto` does. A failed Contacts write
leaves storage unchanged. `sync == nil`: the list shows only the Contacts photo, and
add, swap, and delete of stored photos throw `SidecarUnavailableError`.

`ContactPhotoItem` is public and opaque: `id` (a `String`; a blobId, or a fixed value
for the Contacts-only item), `isCurrent`, `crop`, `addedAt`, and `isAvailable`.

Add `contactPhotoFieldName` to `reservedFieldNames`. `.blob` cells are already hidden
from custom fields. Check every other walker of `.blob` cells.

## UI

New `App/GuessWho/ContactPhotosView.swift`, presented as a sheet, shared by iPhone,
iPad, and Catalyst.

- A grid of photos, newest first, each rendered with its crop through the existing
  rendering helper, off the main thread, bounded to 256 pixels.
- The current photo has a visible "Current" label. Placeholders for pending and
  unavailable photos.
- Each photo opens a menu: View Photo (the existing `ContactPhotoViewer`), Use as
  Current Photo (hidden on the current one), Delete Photo (destructive, with a
  confirmation saying it's removed from all the user's devices, and that the contact
  will have no photo if it's current).
- Toolbar: Done and Add Photo. Add Photo reuses the existing pickers and the crop
  editor, then calls `addContactPhoto`. `PhotoChangeModifier` is private to
  `ContactDetailView.swift`, so move it where both can use it.
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
