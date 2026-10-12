# Highlighted emails

A highlighted email is one email message the user dropped onto a contact to
keep with it: Message-ID, subject, sender name and address, sent date, and the
time it was dropped. The contact card lists them in a "Highlighted Emails"
section, separate from the "Recent Email" section that lists mail the Mail
extension finds automatically ([`mail-activity.md`](mail-activity.md)). Only
metadata is stored — never a message body.

The sender can be ANY address. The user can drop an email from someone related
to the contact, or a thread about them, so a highlighted email says nothing
about when the user last interacted with the contact. That, and the fact that
the user picks each one, is why highlighted emails are a separate cell family
from mail activity:

| | Mail activity | Highlighted email |
|---|---|---|
| Who adds it | The Mail extension, automatically | The user, by a drop |
| Sender | The contact | Any address |
| Moves `lastInteracted` | Yes, forward only | Never |
| Retention | Newest 100 | No limit |
| Removal | None yet | Tombstone |
| Repeat onto a removed one | Stays removed | Revives it |

Read this before touching `HighlightedEmail`, the highlighted-email engine or
repository APIs, or any code that walks every cell of a contact envelope. The
general cell rules this format relies on are in
[`sidecar-compatibility.md`](sidecar-compatibility.md); identity rules are in
[`contact-identity.md`](contact-identity.md).

## Synced format

Each highlighted email is **one cell** on the contact's sidecar envelope (kind
`.contact`, keyed by the contact's GuessWho UUID). There is no new kind and no
new directory.

- **Cell key:** `highlightedEmail:<uuid>`, the email id in lowercase\[^key]. The
  prefix is part of the synced format; never change it.
- **Cell value:** an object with `messageID` (normalized) and `highlightedAt`
  (ISO 8601 UTC, milliseconds), both required, and the optional `subject`,
  `senderName`, `sender` (the From address), and `sentAt` (the Date header,
  ISO 8601), which are omitted when absent\[^value].
- **Cell stamps:** `modifiedAt` is the time of the write that last changed the
  cell, `modifiedBy` that device's id, and `deletedAt` is set when the user
  removed the email.

A cell decodes only when its key has the prefix and a valid UUID, and its value
is an object with a string `messageID` and a valid `highlightedAt`. An optional
member that is not a string (or, for `sentAt`, not a valid date) reads as
absent. A cell that does not decode is hidden from reads, never removed from the
envelope\[^decode].

The key is not a bare UUID and the value has no `field` / `type`, so these cells
are not field instances. `GuessWhoSync.fields(at:)` skips the prefix
explicitly\[^fields], so they never appear in notes, custom fields, the Recently
Deleted screen, or the CLI/MCP field tools, all of which read through it. The
one decode path is `GuessWhoSync.highlightedEmails(at:)`.

## Identity: normalized Message-ID

The email id is **deterministic**, so the same message dropped twice on one
contact — or dropped on two contacts that later collapse — lands on one cell.

1. **Normalize** the Message-ID with the same function mail activity
   uses\[^normalize]: remove all whitespace, strip one enclosing `<` `>` pair,
   and lowercase the part after the last `@`. An ID that is empty after this has
   no identity, and `HighlightedEmail.init` returns nil.
2. **Hash** `"highlighted-email\n" + normalized` with SHA-256 and format the
   first 16 bytes as an RFC 4122 UUID, the same recipe as the mail-activity
   id\[^hash]. The namespace differs from mail activity's, so a message that is
   both a mail activity and a highlighted email on one contact is two cells.

The initializer trims the subject, sender name, and sender address, and treats
an empty string as absent. It rounds `sentAt` and `highlightedAt` to the stored
millisecond precision, so an email read back compares equal to the one
written\[^init].

## Writing

`GuessWhoSync.highlightEmail(_:at:)` does ONE key-locked read-modify-write of
the raw cell map: every cell it does not own is copied through unchanged, and
it returns whether it wrote\[^write].

- **No cell yet:** store the full value. The first write to a contact with no
  envelope mints it (`entityID` = the contact's UUID), like `addField`.
- **A live cell this build decodes:** write this build's keys over the stored
  object. The stored `highlightedAt` is kept (the email was highlighted when it
  was first dropped), a stored optional value survives a drop that has none,
  and keys a newer build added inside the object survive. If the result equals
  the stored object, nothing is written.
- **A soft-deleted cell:** revive it with a fresh live cell that holds this
  drop's full value, including its `highlightedAt`. A drop is an explicit user
  action, so re-dropping a removed email brings it back.
- **A live cell this build cannot decode:** leave it. It belongs to a newer
  build or is malformed.

The write never touches `lastInteracted` or any other cell, and there is no
retention limit: every email the user keeps stays.

## Removing

`GuessWhoSync.removeHighlightedEmail(id:at:)` writes a **tombstone**: the value
is kept, `deletedAt` and `modifiedAt` are set to now, and `modifiedBy` to this
device\[^remove]. It writes nothing when the cell is missing or already
deleted.

The cell is never removed physically. The sidecar merge is a cell-by-cell union
with whole-cell last-writer-wins\[^lww], so a peer whose version still held the
live cell would bring back a cell that was physically removed. The tombstone,
stamped later than the live copy, wins that merge instead.

## Reading

`highlightedEmails(at:)` returns the live, decodable emails in the one public
order: newer `sortDate` first — `sentAt`, or `highlightedAt` for a message with
no Date header — with ties broken by the id string, so every device ranks the
same set the same way\[^order]. It is a pure read: a missing envelope returns
`[]`.

Each engine verb has an async overload that runs the coordinated disk work on a
background queue.

## Repository surface

The app speaks `ContactID` only\[^repo]:

- `highlightedEmails(for:)` is async and runs its read off the main actor. It
  never reconciles or mints; an unreconciled contact returns `[]`. A token
  captured before the contact's identity was minted resolves through the cache
  like `contact(id:)`.
- `highlightEmail(_:for:)` is a write, so it resolves-or-mints the contact's
  GuessWho ID first. A pre-mint token resolves through the cache, so a later
  drop through the same token does not reconcile again. A write that minted
  refreshes the cached record, like `addNote` and the other contact writes.
  **Caller precondition:** a caller awaits each call for a contact before it
  starts the next call for the same contact. A drop of several messages loops
  with `await`, never a task group or one `Task` per message. Calls that start
  before the first has minted each reconcile. The Case-A mint derives the ID
  from the contact's `localID` and display name\[^mint], so they normally
  resolve to the same ID and every email lands on one envelope, at the cost of
  extra Contacts reads and saves, cache refreshes, and reload posts. But if the
  display name changes between two reconciles that both read the contact
  before either saved, they derive different IDs. A save writes the contact's
  whole URL list\[^save], so the later save wins, and the email written under
  the other ID lands on a sidecar that no contact carries.
- `removeHighlightedEmail(id:for:)` never mints: a contact with no GuessWho ID
  has no stored emails, so it returns without a write.

Writes throw `SidecarUnavailableError` when the sidecar engine is unavailable.

### Notifications

- `.contactsRepositoryHighlightedEmailsDidChange` carries `[ContactID]` in
  `ContactsRepositoryHighlightedEmailsDidChangeKey.contactIDs`, and no message
  content.
    - A local write or remove posts it when the stored cell changed. A repeat
      drop or remove that changed nothing posts nothing. When the caller's token
      predates the mint, the list holds both that token and the cache's re-keyed
      token.
    - A watcher delivery that names exact `.contact` keys posts it for the keys
      the cache resolves — the same keys that post
      `.contactsRepositoryMailActivityDidChange`\[^watcher]. The watcher cannot
      say which cells changed, so this also fires for other edits to that
      contact.
- `.contactsRepositoryDidReload` posts only when a write minted the contact
  identity (from the cache refresh, `contactDataChanged: true`). A highlighted
  email moves no cached record and no timestamp, so an ordinary write does not
  post it.
- A **coarse** watcher delivery names no contact and posts only
  `.contactsRepositoryDidReload`. A view that shows highlighted emails must
  observe both notifications.

\[^key]: [HighlightedEmail.cellKey / cellKeyPrefix](../Sources/GuessWhoSync/HighlightedEmail.swift:HighlightedEmail.cellKey)
\[^value]: [HighlightedEmail.cellValue(overlaying:)](../Sources/GuessWhoSync/HighlightedEmail.swift:HighlightedEmail.cellValue)
\[^decode]: [HighlightedEmail.init?(cellKey:cell:)](../Sources/GuessWhoSync/HighlightedEmail.swift:HighlightedEmail.init)
\[^fields]: [GuessWhoSync.fields(at:) skips HighlightedEmail.isCellKey](../Sources/GuessWhoSync/GuessWhoSync.swift:GuessWhoSync.fields)
\[^normalize]: [MailActivity.normalizedMessageID](../Sources/GuessWhoSync/MailActivity.swift:MailActivity.normalizedMessageID)
\[^hash]: [HighlightedEmail.emailID / MailActivity.messageUUID(namespace:normalizedMessageID:)](../Sources/GuessWhoSync/MailActivity.swift:MailActivity.messageUUID)
\[^init]: [HighlightedEmail.init?(messageID:subject:senderName:senderAddress:sentAt:highlightedAt:)](../Sources/GuessWhoSync/HighlightedEmail.swift:HighlightedEmail.init)
\[^write]: [GuessWhoSync.highlightEmail(\_:at:)](../Sources/GuessWhoSync/GuessWhoSync+HighlightedEmail.swift:GuessWhoSync.highlightEmail)
\[^remove]: [GuessWhoSync.removeHighlightedEmail(id:at:)](../Sources/GuessWhoSync/GuessWhoSync+HighlightedEmail.swift:GuessWhoSync.removeHighlightedEmail)
\[^lww]: [merge — whole-cell LWW](../Sources/GuessWhoSync/SidecarMerge.swift:merge)
\[^order]: [HighlightedEmail.sortDate / isNewer(than:)](../Sources/GuessWhoSync/HighlightedEmail.swift:HighlightedEmail.isNewer)
\[^repo]: [ContactsRepository.highlightedEmails(for:) / highlightEmail(\_:for:) / removeHighlightedEmail(id:for:)](../Sources/GuessWhoSync/ContactsRepository.swift:ContactsRepository.highlightEmail)
\[^watcher]: [ContactsRepository.postContactCellsDidChange(forContactKeys:)](../Sources/GuessWhoSync/ContactsRepository.swift:ContactsRepository.postContactCellsDidChange)
\[^mint]: [GuessWhoSync.handleCaseA mints Contact.deterministicGuessWhoID](../Sources/GuessWhoSync/GuessWhoSync.swift:GuessWhoSync.handleCaseA)
\[^save]: [CNContactStoreAdapter.save → apply(\_:to:) sets urlAddresses from the saved value](../Sources/GuessWhoSync/CNContactStoreAdapter.swift:CNContactStoreAdapter.apply)
