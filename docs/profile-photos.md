# Contact profile photos

## Editing

Choose Photo opens the system Photos picker on iPhone/iPad and the native file
picker on Mac Catalyst. A selected or dropped image opens a crop editor before
anything is saved. The editor shows the full image behind a dimmed circular mask.
Drag to position the image and pinch to zoom. The minimum zoom fills the mask;
scrolling and zooming cannot move the circle outside the image. Cancel discards
the selection. Choose saves the original bytes and the selected rectangle.

In contact edit mode, the photo menu also offers Edit Crop, Reset Crop, and
Remove Photo. Edit Crop loads the full original and starts at the stored crop.
Reset Crop clears the rectangle without replacing the original. Existing photos
have no crop and continue to use the full image until edited. There is no
migration or automatic crop write when reading a contact.

## Storage and coordinates

`ContactPhotoCrop` stores normalized `x`, `y`, `width`, and `height`, relative to
the upright image dimensions after applying its orientation. The origin is at
the top left. A circular avatar uses a square rectangle in image pixels, so its
normalized width and height usually differ on a non-square original. The crop
math validates finite, positive, in-bounds rectangles and constrains square
crops to the image. Missing crop metadata means the full photo.

`ContactsRepository.setContactPhoto` sends the full input bytes to Contacts and
preserves those same bytes in the encrypted `profilePhoto` blob beside the
contact envelope. It never writes the displayed cropped image as the original.
The optional `photoCrop` object lives inside that blob pointer, so normal
whole-cell synchronization keeps the rectangle attached to its original image.
The active photo uses one fixed cell ID per contact, so simultaneous first edits
on different devices converge to one original/crop pair. Crop commits check the
original that the editor showed; a replacement makes the stale editor report an
error instead of applying its rectangle to a different image.
The slot is reserved and hidden from custom fields. The existing `previousPhoto`
snapshot still captures replaced original bytes. Replacing a photo clears the
old crop unless the caller supplies a new one; removing a photo deletes the
active pointer as well as the Contacts photo.
If committing storage fails after a Contacts write, the repository restores the
previous system photo and reports the failure. A failure to restore is also
reported, rather than presented as a successful save.

`setContactPhotoCrop` retains the original bytes and changes only the selected
rectangle (using the existing blob replacement path). It does not write to the
Contacts image property. Editing a photo that predates crop support preserves
the full image returned by Contacts at that time. If Contacts only has a
thumbnail, the existing thumbnail fallback supplies the available image.

## Changes made in Contacts.app

An external replacement becomes the new full original with no crop; external
removal removes the active photo. The outgoing original goes into the existing
previous-photo slot. Unrelated contact edits do not change the crop.

Tracking adds one `systemPhotoDigest` SHA-256 hash to the synced photo pointer.
It describes the bytes Contacts returns after the write, which may differ from
the selected file. Local preferences hold two hashes per contact UUID: the
original last observed and the system image last observed. No photo bytes or
Contacts-local identifiers go into preferences. These baselines survive relaunch
and are updated during photo reads; they are not themselves synced.

A device seeing an original for the first time establishes its local baseline.
Subsequent system-image changes replace that original and clear its crop, except
when the expected system-image hash arrives: Contacts sync and photo-file sync
can finish in either order, and that expected arrival preserves the crop. An
unseen system change before the first baseline cannot be distinguished from
initial synchronization; the first observation trusts the preserved original.

## Rendering and refresh

`contactPhotoData` returns original data plus optional crop metadata for both
thumbnail and full-size requests. Stored originals take precedence over system
thumbnails, whose framing may already differ. The pointer and bytes are read
under the same storage lock. A pending original download remains retryable.

The shared `ContactPhotoLoader` renders the rectangle for avatars, lists, and
contact details. `ContactPhotoRendering` draws in upright image coordinates,
including rotated and mirrored source images, without altering persisted data.
Import comparisons and the Mail contact snapshot use the same rendering helper.
Thumbnail rendering is bounded to 256 pixels. A full-screen photo opened from
the header shows the same crop; Edit Crop always retrieves the original.

Photo writes refresh the contact-data revision. Remote envelope changes compare
previously loaded photo pointers and invalidate photo consumers when a pointer
changes; unrelated notes and timestamp changes retain their inexpensive refresh.

## Verification

`ContactPhotoCropTests` covers landscape/portrait fit, pan limits, minimum zoom,
resolution independence, invalid rectangles, and JSON round trips.
`ContactPhotoCropPersistenceTests` covers original-byte preservation, repository
reload, crop changes and reset, replacement/removal, an existing uncropped photo,
encrypted filesystem storage reopened through a fresh engine, and simultaneous
first edits. `ContactPhotoSourceTests` covers external replacement/removal after
relaunch, unrelated edits, stale crop editors, failed storage writes, pending
download refresh, and expected system-image arrival. App rendering tests check
that large uncropped originals still produce bounded Mail thumbnails after reset.

Hand-check on iPhone/iPad and Mac Catalyst: choose a portrait and a landscape
image, drag to every edge, pinch to minimum and maximum zoom, cancel a replacement,
confirm a crop, reopen Edit Crop, reset it, and inspect list/favorite/detail/Mail
photos. Repeat with an EXIF-rotated photo and resize the editor while zoomed.
