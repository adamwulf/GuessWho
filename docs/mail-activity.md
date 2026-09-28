# Mail activity

A mail activity records one email message against a contact: sender address,
subject, received time, Message-ID, and an optional deep link back to the
message in Mail. The Apple Mail action handler queues incoming message
metadata; the app resolves the sender to contacts and records one activity on
each. Only metadata is stored — never a message body.

Read this before touching `MailActivity`, the mail-activity engine or
repository APIs, or any code that walks every cell of a contact envelope. The
general cell rules this format relies on are in
[`sidecar-compatibility.md`](sidecar-compatibility.md); identity rules are in
[`contact-identity.md`](contact-identity.md).

## Synced format

Each activity is **one cell** on the contact's sidecar envelope (kind
`.contact`, keyed by the contact's GuessWho UUID). There is no new kind and no
new directory.

- **Cell key:** `mailActivity:<uuid>`, the activity id in lowercase[^key]. The
  prefix is part of the synced format; never change it.
- **Cell value:** an object with `direction` (`"incoming"`), `sender`,
  `receivedAt` (ISO 8601 UTC, milliseconds), `messageID` (normalized), and the
  optional `subject` and `mailURL`, which are omitted when absent[^value].
- **Cell stamps:** `modifiedAt` is the time of the write that last changed the
  value, `modifiedBy` that device's id.

The key is not a bare UUID and the value has no `field` / `type`, so these
cells are not field instances. `GuessWhoSync.fields(at:)` skips the prefix
explicitly[^fields], so they never appear in notes, custom fields, the
Recently Deleted screen, or the CLI/MCP field tools, all of which read through
it. The one decode path is `GuessWhoSync.mailActivities(at:)`.

## Identity: normalized Message-ID

The activity id is **deterministic**, so every delivery of one message — a
repeat from the handler, the same message on another Mac, or the same message
recorded on two contacts that later collapse — lands on the same cell.

1. **Normalize** the RFC 5322 Message-ID[^normalize]: remove all whitespace
   (header folding), strip one enclosing `<` `>` pair, and lowercase the part
   after the last `@`. Domains are case-insensitive; the local part is not, so
   it keeps its case. An ID that is empty after this has no identity, and
   `MailActivity.init` returns nil.
2. **Hash** `"mail-activity\n" + normalized` with SHA-256 and format the first
   16 bytes as an RFC 4122 UUID (version and variant bits set, the same recipe
   as `Event.stableID(forEventKitID:)`)[^hash]. The namespace prefix keeps a
   Message-ID from hashing to the id of anything else.

The stored `messageID` is the normalized form. `receivedAt` is rounded to the
stored millisecond precision when the value is built, so an activity read back
compares equal to the one written.

## Writing

`GuessWhoSync.recordMailActivity(_:at:)` does ONE key-locked read-modify-write
of the raw cell map: every cell it does not own is copied through
unchanged[^write]. In that one write it:

1. **Upserts the activity cell.**
   - No cell yet: store the full value.
   - A live cell this build decodes: write only this build's keys over the
     stored object. Keys a newer build added inside the object survive, and a
     stored `subject` or `mailURL` survives a delivery that has none. If the
     result equals the stored object, nothing is written.
   - A soft-deleted cell: leave it. A repeat delivery never undeletes.
   - A live cell this build cannot decode (an unknown `direction`, a missing
     required key): leave it. It belongs to a newer build.
2. **Applies retention** (below).
3. **Advances `lastInteracted`** (below).

The whole call writes nothing when none of the three changed anything, so a
repeat delivery is a true no-op: no write, no watcher echo, no notification.

## `lastInteracted`: a forward-only timestamp

The write moves the contact's `lastInteracted` cell to the message's
`receivedAt`, but **only forward**: a message older than the stored value
(processed late, or after the user logged a newer interaction) leaves it
alone.

When it moves, the cell's value AND its `modifiedAt` are both the received
time. Every timestamp stamp writes that same shape (value == `modifiedAt`), so
the whole-cell last-writer-wins merge picks the cell with the later value: two
Macs that each record a different message converge on the later received time,
even when the older message was written at a later wall-clock time[^lww].

The activity cell itself is different: its `modifiedAt` is the write time, so
the newest change to a message's stored value wins a merge.

## Retention

Each contact keeps at most `MailActivity.retentionLimit` (100) activities[^retention].

- Only **decodable live** activity cells count. Soft-deleted cells and cells
  this build cannot decode are never counted and never removed.
- They rank newest first by `receivedAt`, ties broken by the id string — the
  same order `mailActivities(at:)` returns — so every device keeps the same
  set.
- The write physically removes every counted cell beyond the limit. A delivery
  that would rank outside the window is not added.
- Removal is physical, not a tombstone. A merge can therefore leave more than
  the limit: a device that still has a removed cell brings it back, and a
  Case-D collapse unions two contacts' activities. Reads return every decodable
  live activity until the next mail-activity write on that contact trims the
  set again; because the order is deterministic, devices converge on the same
  set.

## Deletion

There is no delete action yet. A future one must write a tombstone
(`deletedAt`) rather than remove the cell, because a repeat delivery would
recreate a missing cell but never undeletes a tombstoned one.

## Reading

`mailActivities(at:)` returns the live, decodable activities, newest first. It
is a pure read: a missing envelope returns `[]`.

## Repository surface

The app speaks `ContactID` only[^repo]:

- `recordMailActivity(_:for:)` is a write, so it resolves-or-mints the contact's
  GuessWho ID. A token captured before the mint resolves through the cache
  first, so a batch of messages queued against that token mints once. The disk
  work runs off the main actor.
- `mailActivities(for:)` is async and runs its read off the main actor. It never
  reconciles or mints; an unreconciled contact returns `[]`. A pre-mint token
  resolves through the cache like `contact(id:)`.

### Notifications

- `.contactsRepositoryMailActivityDidChange` carries `[ContactID]` in
  `ContactsRepositoryMailActivityDidChangeKey.contactIDs`, and no message content.
  - A local write posts it when the activity list changed (added, changed, or
    pruned). When the caller's token predates the mint, the list holds both
    that token and the cache's re-keyed token.
  - A watcher delivery that names exact `.contact` keys posts it for the keys
    the cache resolves. The watcher cannot say which cells changed, so this also
    fires for other edits to that contact.
- `.contactsRepositoryDidReload` posts when `lastInteracted` moved
  (`contactDataChanged: false`), or once with `contactDataChanged: true` when
  the write minted the contact's identity.
- A **coarse** watcher delivery (a kind directory, or unknown scope) names no
  contact and posts only `.contactsRepositoryDidReload`. A view that shows mail
  activity must observe **both** notifications.

[^key]: [MailActivity.cellKey / cellKeyPrefix](../Sources/GuessWhoSync/MailActivity.swift:MailActivity.cellKey)
[^value]: [MailActivity.cellValue(overlaying:)](../Sources/GuessWhoSync/MailActivity.swift:MailActivity.cellValue)
[^fields]: [GuessWhoSync.fields(at:) skips MailActivity.isCellKey](../Sources/GuessWhoSync/GuessWhoSync.swift:GuessWhoSync.fields)
[^normalize]: [MailActivity.normalizedMessageID](../Sources/GuessWhoSync/MailActivity.swift:MailActivity.normalizedMessageID)
[^hash]: [MailActivity.activityID(forNormalizedMessageID:)](../Sources/GuessWhoSync/MailActivity.swift:MailActivity.activityID)
[^write]: [GuessWhoSync.recordMailActivity(_:at:)](../Sources/GuessWhoSync/GuessWhoSync+MailActivity.swift:GuessWhoSync.recordMailActivity)
[^lww]: [merge — whole-cell LWW](../Sources/GuessWhoSync/SidecarMerge.swift:merge)
[^retention]: [GuessWhoSync.pruneMailActivities / MailActivity.isNewer(than:)](../Sources/GuessWhoSync/GuessWhoSync+MailActivity.swift:GuessWhoSync.pruneMailActivities)
[^repo]: [ContactsRepository.recordMailActivity(_:for:) / mailActivities(for:)](../Sources/GuessWhoSync/ContactsRepository.swift:ContactsRepository.recordMailActivity)
