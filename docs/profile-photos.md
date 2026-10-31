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
preserves those same bytes in the `profilePhoto` blob beside the contact
envelope. It never writes the displayed cropped image as the original.
The optional `photoCrop` object lives inside that blob pointer, so normal
whole-cell synchronization keeps the rectangle attached to its original image.
The active photo uses one fixed cell ID per contact, so simultaneous first edits
on different devices converge to one original/crop pair. Crop commits check the
original that the editor showed; a replacement makes the stale editor report an
error instead of applying its rectangle to a different image. This check also
requires the slot to remain absent when editing a system-only photo for the
first time.
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
synced yet, shows the Contacts photo, uncropped. Edit Crop and Reset Crop then
report an error and leave the file alone, because another device may still be able
to read it. Replacing the photo still works: choosing a new one, or saving a
LinkedIn import with its photo row checked. That row starts checked, as it does for
any photo, and the sheet shows the change before Save. The Contacts photo moves to
`previousPhoto`, and the older file and its crop are deleted on every device.

A build from before this change can't read the new files. It shows no photo for
those contacts, not even the Contacts one, and its crop edits fail before writing,
so nothing is corrupted. Update every device.

## Changes made in Contacts.app

An external replacement displays the current full Contacts image with no crop;
external removal displays no photo. Unrelated contact edits do not change the
crop. Detection records a local override, without writing a competing synced
photo cell. The outgoing preserved original remains stored until an explicit
photo save, removal, or recrop moves it into the existing previous-photo slot.
Recropping an external replacement preserves its full Contacts bytes as the new
original.

Tracking adds one `systemPhotoDigest` SHA-256 hash to the synced photo pointer.
It describes the bytes Contacts returns after the write, which may differ from
the selected file. Local preferences hold two hashes per contact UUID (the
original last observed and the system image last observed), plus the ignored
blob ID when an external change overrides the preserved photo. No photo bytes
or Contacts-local identifiers go into preferences. This state survives relaunch
and is updated during photo reads; it is not itself synced.

A device seeing an original for the first time establishes its local baseline.
Subsequent unexpected system-image changes enable the override. A different
preserved original clears it. For a new crop of the same original, the override
clears when both a new blob pointer and its expected system-image hash arrive.
While waiting, the earlier ignored blob ID is retained. Contacts sync and
photo-file sync can finish in either order without a photo read overwriting the
incoming original/crop. An unseen system change before the first baseline cannot
be distinguished from initial synchronization; the first observation trusts the
preserved original.

## Rendering and refresh

`contactPhotoData` returns original data plus optional crop metadata for both
thumbnail and full-size requests. Unless a system-image change overrides them,
stored originals take precedence over system thumbnails, whose framing may
already differ. The pointer and bytes are read
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
