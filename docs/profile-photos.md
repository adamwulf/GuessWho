# Contact profile photos

A contact can hold many photos, and one of them is current. Contacts holds only
the current photo, so Contacts.app and everything else that reads Contacts see just
that one. Changing the photo always keeps the previous one on the contact.

## Editing

Choose Photo opens the system Photos picker on iPhone/iPad and the native file
picker on Mac Catalyst. A selected or dropped image opens a crop editor before
anything is saved. The editor shows the full image behind a dimmed circular mask.
Drag to position the image and pinch to zoom. The minimum zoom fills the mask;
scrolling and zooming cannot move the circle outside the image. Cancel discards
the selection. Choose saves the original bytes and the selected rectangle, and
makes the photo current.

In contact edit mode, the photo menu also offers Edit Crop, Reset Crop, Remove
Photo, and All Photos. Edit Crop loads the full original and starts at the stored
crop. Reset Crop clears the rectangle without replacing the original. Existing
photos have no crop and continue to use the full image until edited. There is no
migration or automatic crop write when reading a contact. Remove Photo stops using
the photo as current: the contact then shows no photo, and the photo stays in All
Photos.

## All Photos

`ContactPhotosView` is a sheet shared by iPhone, iPad, and Catalyst. It opens from
the edit-mode photo menu, always, and from a button in the full-screen viewer opened
from the header. The viewer opened from inside All Photos has no such button.

It shows a grid of photos, newest first, each drawn with its own crop through
`ContactPhotoRendering`, off the main thread, at up to 600 pixels, since a tile can be
about 540 pixels wide on a 3x iPhone. The current photo is labeled. Each cell loads its
own thumbnail, so only visible photos are read. VoiceOver reads when each photo was added
and which is current.

Each photo's menu offers View Photo, Use as Current Photo (not on the current one),
and Delete Photo, which asks first and says the photo is removed from all the user's
devices, and that the contact will have no photo if it's current. A photo with no bytes
here reads "Not available right now" and offers only Delete Photo. The view can't tell a
file on its way from one that's gone until it tries: the first reports it's still
downloading and to try again shortly, and the second is cleared. A read that fails reads
"Couldn't load this photo" and has no actions, because a failed read can't rule out an
older file another device may still read; the next reload tries again. A photo this
device can't read shows a placeholder with no actions, for the same reason.

The Mac file panel is modeless, so while it's open Done and Add Photo are disabled, as
are Choose Photo and All Photos on the contact card.

Add Photo uses the same pickers and crop editor, and doesn't change the current photo
unless the contact shows none. Choosing a photo makes it current, restoring that
photo's crop. Deleting the current photo clears it from Contacts too, and no other
photo becomes current on its own.

The sheet reloads on `.contactsRepositoryDidReload`, so a photo arriving from another
device appears. After a change it invalidates `ContactPhotoLoader` and refreshes the
header.

## Storage

A photo is a `.dat` file beside the contact envelope, plus a pointer to it. The
pointer's optional `photoCrop` lives inside it, so normal whole-cell synchronization
keeps the rectangle attached to its original image.

Three `.blob` cell names hold pointers, and the photos on a contact are the union of
all their live cells, deduplicated by blobId:

- **`contactPhoto`** (`ContactsRepository.contactPhotoFieldName`). Every stored photo
  has one, whose cell key is the blobId's UUID uppercased. One blob, one key, so two
  devices adding the same blob converge. Its `createdAt` is when the photo was added.
  It is written once, and later only for a crop change or to delete it.
- **`profilePhoto`**. One fixed cell per contact naming the current photo, holding a
  copy of its pointer. Simultaneous first edits on different devices converge to one
  original/crop pair.
- **`previousPhoto`**. The one previous photo older builds kept. A live one is just
  another photo on the contact. It is read, and never written except to delete it.

All three are reserved and hidden from custom fields.

Merge is whole-cell last-writer-wins, so moving pointers between cells could lose a
photo in a race: one device's pointer could overwrite another's. With one add-only
cell per photo, a race over which photo is current can't lose one. No migration is
needed.

Every write happens under the key's lock, with the `.dat` first and then one envelope
write. A new photo's cell and any `profilePhoto` update land in that one write, so a
racing device can't lose it. Writing these fields never deletes a superseded `.dat`.
Before `profilePhoto` is repointed or removed, a pointer with no `contactPhoto` cell
gets one, stamped with the pointer's own `modifiedAt` so a delete this device hasn't
seen still beats it. A key holding a tombstone gets no new cell, because that photo was
deleted on another device. A photo whose `contactPhoto` key holds a tombstone counts as
deleted, whatever else still names it: it isn't listed, and it isn't current.

### What races do

- **Two devices change the current photo.** The later stamp wins, and both photos stay
  on the contact.
- **One device deletes a photo while another makes it current.** The photo stays
  deleted in either order. The later swap can leave `profilePhoto` naming it, but it
  counts as deleted, so the contact has no stored current photo and shows whatever
  Contacts holds.
- **One device deletes older data that another replaces.** It stays deleted in either
  order, because the delete writes a tombstone at the `contactPhoto` key even with no
  cell there. If the delete has the later stamp it also tombstones `profilePhoto`, so
  the replacement stays on the contact but isn't current.
- **One device deletes a photo while another crops it.** A crop with the earlier stamp
  loses. A crop with the later stamp wins the cell, so the photo comes back with its
  file gone. It shows as a placeholder, and deleting it again clears it.
- **One device crops a photo while another changes the current one.** The crop stays
  with its photo. If the crop has the later stamp it also makes that photo current
  again, because a crop writes `profilePhoto`.

Racing swaps, or a crop against a swap, can leave Contacts and `profilePhoto` disagreeing
on two devices: `profilePhoto` follows the later stamp, and Contacts follows its own
sync, and a crop doesn't write Contacts at all. A device then treats Contacts' bytes as
an external change, or on its first look at that photo, trusts the pointer. Choosing the
photo again puts Contacts right.

**The same image is never stored twice** by a new write. Identity is the bytes'
SHA-256, compared against the readable photos on the contact, reading only those with
the same `byteCount`. So re-importing a LinkedIn photo or choosing the same file
reuses the existing photo, with the new crop if there is one, or its own. Dedup applies
to new writes only. Existing data can hold the same bytes under two blobIds, from an
old repeat import, and the list can't see that without reading bytes, so both show.
Two devices adding the same image at the same moment also mint two photos.

**There is no limit** on the number of photos.

## Operations

`ContactsRepository.setContactPhoto` sends the full input bytes to Contacts and
stores those same bytes. It never writes the displayed cropped image as the original.
Its steps:

1. If what's showing is a Contacts photo with no stored original, or an external
   Contacts change overrode the stored one, store those Contacts bytes as a photo
   first. This is best-effort. If the change then fails and Contacts ends up holding
   those bytes again, this store is undone, so they aren't listed twice. The undo
   leaves one tombstoned cell, which nothing shows. If restoring Contacts fails too,
   the stored copy stays, because it's the only one left.
2. If the bytes match the current photo, the crop is unchanged, and Contacts still
   holds what the pointer's `systemPhotoDigest` says, return without writing anything,
   so a repeated import doesn't churn. If Contacts has drifted, this writes it again.
   With the same bytes under two blobIds in older data, the current photo is the one
   matched.
3. Write Contacts, then commit. If the commit fails, the repository restores the
   previous system photo and reports the failure. A failure to restore is also
   reported, rather than presented as a successful save.

With a nil image, it does step 1, clears Contacts, and tombstones `profilePhoto`. The
photos stay.

`setContactPhotoCrop` updates the pointer in `profilePhoto` and in that photo's
`contactPhoto` cell, and doesn't touch the file or the Contacts image. Crop commits
check the original that the editor showed; a replacement makes the stale editor report
an error instead of applying its rectangle to a different image. This check also
requires the slot to remain absent when editing a system-only photo for the first time.
Two cases do write bytes: a first crop of a photo only Contacts holds, which preserves
the full image returned by Contacts at that time, and adopting an external Contacts
change, where the stored original stays as a photo. If Contacts only has a thumbnail,
the existing thumbnail fallback supplies the available image.

`contactPhotos(for:)` lists the photos, newest first, as opaque `ContactPhotoItem`s.
It adds an item for the photo only Contacts holds when no stored photo stands for it:
no stored current photo, or an external change. It reads pointers, apart from the
current photo's file and the Contacts image, which spotting an external change needs.
A `profilePhoto` cell with no `contactPhoto` cell uses its `modifiedAt` for the order,
because the slot keeps the `createdAt` of the contact's first photo across repoints.

`contactPhotoData(for:photoID:)` reads one photo's bytes and crop. A file still
downloading returns nil and starts its download. A read that fails throws
`photoReadFailed`, because Foundation's text names the file and must not reach an alert.

`addContactPhoto` stores a photo, and makes it current through `setContactPhoto` if
the contact shows none.

`setCurrentContactPhoto` reads the chosen bytes, does step 1, writes them to Contacts,
repoints `profilePhoto` at that photo with its crop and a fresh `systemPhotoDigest`,
and restores Contacts on failure. It refuses a photo whose file is downloading or
can't be read here.

`deleteContactPhoto` tombstones every live cell naming the photo, then deletes the
`.dat`. If the photo is current it clears Contacts first, restoring on failure. For
the photo only Contacts holds, it just clears Contacts. It refuses an older file this
device can't read, and a read that fails, which can't rule that out. Delete promises the photo is gone from every device, so what it
does also depends on the file, checked before any write:

- **Present:** deleted as above.
- **Only an iCloud placeholder on this device:** a placeholder can't be removed, so the
  file would stay in iCloud. The delete starts its download, throws `photoPending`, and
  changes nothing, including Contacts when the photo is current.
- **Truly missing, with no placeholder**, as when an older build deleted it: the delete
  tombstones the cells, so a photo stuck waiting for its file can always be cleared.

All of these post the same refresh `setContactPhoto` does. A failed Contacts write
leaves storage unchanged. With no storage (`sync == nil`), the list shows only the
Contacts photo, and adding, choosing, or deleting a stored photo throws
`SidecarUnavailableError`.

An identity merge moves the losing identity's `.dat` files to the winner. See
[Contact identity](contact-identity.md).

## Coordinates

`ContactPhotoCrop` stores normalized `x`, `y`, `width`, and `height`, relative to
the upright image dimensions after applying its orientation. The origin is at
the top left. A circular avatar uses a square rectangle in image pixels, so its
normalized width and height usually differ on a non-square original. The crop
math validates finite, positive, in-bounds rectangles and constrains square
crops to the image. Missing crop metadata means the full photo.

## Blob files and older encrypted photos

Photo `.dat` files are not encrypted, like everything else in the iCloud folder.
A file starts with a short marker followed by the image bytes, so saving or
reading one never touches the keychain. The marker lives in the file, so the
synced JSON didn't change.

Older builds wrote AES-GCM sealed files under a key in the iCloud keychain, and a
file with no marker is treated as one of those. It is decrypted where that key can
be reached. Mac Catalyst can't reach it: the app claims `<TeamID>.` App Groups
that its provisioning profile doesn't authorize, so macOS ignores the app's
entitlements for the keychain, which answers `-34018`. The profile can't be changed to allow them:
`<TeamID>.` groups can't be registered on the Apple Developer site, and the
Catalyst profiles list only the `group.` ID.

A device that can't open an older file, including a new device whose key hasn't
synced yet, shows the Contacts photo, uncropped. Only reading the file can detect
this, so its item in All Photos reads as available until a read fails, and that mark
lives in memory. The grid reads each visible photo, so it flips right away. Another
device may still be able to read the file, so this device leaves it alone: Edit Crop
and Reset Crop report an error, it can't be made current or deleted, and it shows as a
placeholder with no actions. Replacing the photo still works, by choosing a new one,
using the CLI/MCP set-photo tool, or saving a LinkedIn or TLS roster import with its
photo row checked. That row starts checked, as it does for any photo. A single-profile
sheet shows the change before Save, but a roster import can include people you never
paged to. The older file stays on the contact with its crop, and Contacts' copy of it
isn't stored as well, because a stored original exists.

A build from before the marker can't read the new files. It shows no photo for
those contacts, not even the Contacts one, and its crop edits fail before writing,
so nothing is corrupted. Update every device.

## Changes made in Contacts.app

An external replacement displays the current full Contacts image with no crop;
external removal displays no photo. Unrelated contact edits do not change the
crop. Detection records a local override, without writing a competing synced
photo cell. The outgoing preserved original stays a stored photo, and an explicit
photo save, removal, or recrop stores the Contacts bytes as a photo too. Recropping
an external replacement preserves its full Contacts bytes as the new original.

Tracking adds one `systemPhotoDigest` SHA-256 hash to the synced photo pointer.
It describes the bytes Contacts returns after the write, which may differ from
the selected file. Local preferences hold two hashes per contact UUID (the
original last observed and the system image last observed), plus the ignored
pointer revision when an external change overrides the preserved photo. A revision is
the blobId plus the `profilePhoto` cell's `modifiedAt`, so it changes with every
explicit write, including choosing the same photo again. No photo bytes or
Contacts-local identifiers go into preferences. This state survives relaunch and is
updated during photo reads; it is not itself synced.

A device seeing an original for the first time establishes its local baseline.
Subsequent unexpected system-image changes enable the override. A different
preserved original clears it. For the same original, the override clears when both a
new pointer revision and its expected system-image hash arrive. While waiting, the
earlier ignored revision is retained. Contacts sync and photo-file sync can finish in
either order without a photo read overwriting the incoming original/crop. An unseen
system change before the first baseline cannot be distinguished from initial
synchronization; the first observation trusts the preserved original.

## Rendering and refresh

`contactPhotoData(for:kind:)` returns original data plus optional crop metadata for
both thumbnail and full-size requests. Unless a system-image change overrides them,
stored originals take precedence over system thumbnails, whose framing may
already differ. The pointer and bytes are read
under the same storage lock. A pending original download remains retryable.

A current photo whose file isn't here, with no iCloud placeholder either, shows the
Contacts photo, uncropped, rather than going blank. The file may still arrive, because
the JSON can land before the file's placeholder does, or may be gone for good, as when
an older build deleted it. Its item stays current in All Photos as a placeholder. Because
Contacts' copy could be the last one, changing the photo stores it first, and Edit Crop
adopts it as a new photo. When the file does arrive, photo consumers are told.

The shared `ContactPhotoLoader` renders the rectangle for avatars, lists, and
contact details. `ContactPhotoRendering` draws in upright image coordinates,
including rotated and mirrored source images, without altering persisted data.
Import comparisons and the Mail contact snapshot use the same rendering helper.
Thumbnail rendering is bounded to 256 pixels. A full-screen photo opened from
the header shows the same crop; Edit Crop always retrieves the original.

Photo writes refresh the contact-data revision. Remote envelope changes compare
the pointer and `modifiedAt` a photo consumer last loaded, and invalidate photo
consumers when either changes, when the current photo is removed, or when a missing
file arrives. The stamp matters because choosing a photo again can leave the pointer
identical. Unrelated notes and timestamp changes retain their inexpensive refresh. The
list and the reads before a write don't count as loading: they'd hide a change from
`ContactPhotoLoader`, which still holds the old image.

## Verification

`ContactPhotoLibraryTests` runs on both the in-memory store and
`FileSystemSidecarStore` with a keychain that refuses every call. It covers replacing,
adding, choosing, removing, and deleting; a photo only Contacts holds and an external
change; dedup; a crop edit writing no new file; existing data with no migration;
merging two changes to the current photo; failed Contacts and storage writes; an
unreadable older file; a file still downloading; and no storage.
`IdentityMergePhotoFileTests` covers the files an identity merge moves.
`ContactPhotoCropTests` covers landscape/portrait fit, pan limits, minimum zoom,
resolution independence, invalid rectangles, and JSON round trips.
`ContactPhotoCropPersistenceTests` covers original-byte preservation, repository
reload, crop changes and reset, replacement/removal, an existing uncropped photo,
filesystem storage reopened through a fresh engine, saving with no usable keychain,
an older encrypted file this device can't open, and simultaneous first edits and
absent-to-present crop races. `ContactPhotoSourceTests` covers external replacement/removal after
relaunch, unrelated edits, stale crop editors, failed storage writes, pending
download refresh, and both sync arrival orders. Catalyst rendering tests check
that large uncropped originals still produce bounded Mail thumbnails after reset.

Hand-check on iPhone/iPad and Mac Catalyst: choose a portrait and a landscape
image, drag to every edge, pinch to minimum and maximum zoom, cancel a replacement,
confirm a crop, reopen Edit Crop, reset it, and inspect list/favorite/detail/Mail
photos. Repeat with an EXIF-rotated photo and resize the editor while zoomed.

Also hand-check All Photos on both: see every photo, add one without the current photo
changing, remove the current photo and see it stay, make an older photo current and
see its crop come back, delete a photo and the current photo, a photo syncing between
devices, and the Contacts.app view of each change. Then, on both:

- The viewer's All Photos button versus its X, and View Photo from the grid, which has
  no such button.
- Add Photo with no current photo, and the empty state.
- The crop editor's error alert.
- Choosing the same photo twice.
- The monogram returning after Remove and after Delete.
- All Photos reachable in edit mode, and a drop on the monogram.
- A file still downloading (Delete refused), a missing file (Delete clears it), and an
  unreadable older file on Mac.
- An unsaved + record after adding or swapping: Cancel asks, and Back keeps it.
- Typed edits plus an All Photos change, then Done and Cancel.
- Tapping tile edges on wide uncropped photos.
- VoiceOver.
- A narrow iPhone and a small Mac window.
- Done and Add Photo while the file panel is open.
- `.fullScreenCover` from the sheet on Catalyst, and the full-tile Menu label on Catalyst.
- The crop sheet opening as the Photos picker closes.
