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

## App

### Dropping an email

The whole contact card is the drop target: one UIKit `UIDropInteraction` sits
on the backing `UICollectionView` of the card's outermost container, the
`List`, so a drop anywhere on the profile works. There is no drop zone and no
drop highlight\[^drop].

- **Why not SwiftUI's `.onDrop`:** SwiftUI bug FB24490454. A SwiftUI `List`
  on iOS and Mac Catalyst is a `UICollectionView`, and the collection view
  has a built-in `UIDropInteraction`. That interaction claims every drop
  session from another app over the list and then refuses it, so a SwiftUI
  `.onDrop` on the `List` never sees a Mail drag. The author of the
  workaround this follows found that a second interaction next to the
  built-in one is not enough, because the built-in one still wins over the
  cells:
  <https://developer.apple.com/forums/content/attachment/75bcafd5-b927-465a-9648-b8fc856f556f>.
- **How it is installed:** `ListMailDropTarget` is an invisible,
  non-interactive `.background` on the `List`\[^install]. It searches only
  inside the card's own view controller: it follows the responder chain
  (`next`, not the superviews, because a hosting view's next responder is not
  always its controller) to the nearest `UIViewController`, the card's
  hosting controller, and searches that controller's view, breadth first, for
  a `UICollectionView` whose frame overlaps its own. It never looks above that
  view. A collection view behind the card, or the card below during an
  animated navigation push, overlaps the card too, and a search of the whole
  window took those (measured in review on Catalyst, before this rule). The
  list's collection view can join the view tree after its background joins
  the window, so the search runs up to 20 times, 100 ms apart. If the
  collection view the target holds leaves the target's window, the target
  gives it back its own interactions and searches again. While the target is
  enabled, it removes the collection view's other drop interactions, keeps
  them, and adds its own. Every SwiftUI update checks again, in case UIKit or
  SwiftUI adds a drop interaction later; it is removed and kept the same way.
  When SwiftUI removes the background, the target removes its own interaction
  and adds the kept ones back. Only public UIKit API is used. The
  workaround's author notes that removing the built-in
  interaction also turns off the `List`'s own drop handling (`.onMove`,
  `.onInsert`, drops onto rows); the card uses `.onMove` only in the editor,
  where the kept interactions are back.
- **What it accepts:** the delegate's `canHandle` returns
  `MailDropReader.canAccept(_:)` for the providers of the session's items,
  and `performDrop` checks the same again\[^accept]. A provider
  counts when it has Mail's message type (`com.apple.mail.email`) or
  `public.email-message` — a Finder `.eml` has these too. A provider with
  only a URL counts when it is neither `public.file-url` nor `public.image`:
  Catalyst may expose only Mail's `message:` URL, and a web, `mailto:`, or
  `tel:` link adds a website, an email address, or a phone number (see
  "Dropping a web, mailto:, or tel: link"), but a Finder file (whose
  `public.file-url` conforms to `public.url`) or a dragged image would
  otherwise make the whole card accept a drop that adds nothing. Only the
  type is known before the drop, not the scheme, so a URL of any other
  scheme (`ftp:`, `sms:`, …) is accepted too; the reader finds neither a
  Message-ID nor a contact value in it, so it adds nothing\[^read]. The
  reader turns each dragged message into `EmailMessageHeaders`. Any message
  is kept, from any sender.
- **No drop while the user edits the contact.** The section is hidden during
  the edit, so the target is disabled: it removes its own interaction and adds
  the kept ones back, because the inline editor pins edit mode and uses
  `.onMove` drag-handle reorder, which may need them. The installer is the
  one owner of this state; the delegate has none, because UIKit asks it only
  while its interaction is on the list.
- **Data requests start inside `performDrop`**, because UIKit allows them only
  there: `dropInteraction(_:performDrop:)` takes the providers of the
  session's items, calls `MailDropReader.startLoading(_:)` synchronously, and
  hands the result to `addDroppedItems(_:)`, where a task awaits
  `MailDropReader.read(_:)`. Every load starts there, the late `.eml` (see
  "Two phases") too. `sessionDidUpdate` proposes `.copy`.
- **No system progress UI.** Before any load starts, `performDrop` sets the
  session's `progressIndicatorStyle` to `.none`\[^progress]. By default UIKit
  shows "progress and cancellation UI … if handling this session's drop
  takes a significant amount of time" (`UIDragSession.h`), and every load
  started in `performDrop` counts toward that progress. In a hand test on
  Catalyst, UIKit's progress HUD showed while Mail's `.eml` loaded (about
  29 s). After the HUD went away, that window looked normal and still drew
  updates (a remove made in a second window showed up in it), but it took
  no input; a second window worked, and a sample showed every thread idle
  (no app frames). The system progress UI is the likely cause, so turning
  it off is expected to prevent this; that is not measured. The card shows
  the drop's result itself: the row appears at once and fills in later. A
  test cannot make a `UIDropSession`, so only a hand test shows the effect,
  and it must check that the window still takes input after the row fills
  in, not only that no HUD shows.
- **Two phases for a Mail message.** On Catalyst a Mail drag's provider
  carries both the `.eml` file promise and the `message:` URL. In a hand
  test the `.eml` arrived about 29 s after the drop (likely a 30 s
  file-promise timeout), but it did arrive, and the row it built (sender,
  sent date) was right. So the file is kept, but it never delays the
  row\[^twoPhase]:
    1. **Fast.** When the provider's `message:` URL gives a Message-ID,
       `read` returns the message without waiting for the `.eml`: the
       Message-ID, and a subject from Mail's plain text, else the suggested
       file name. The card writes it at once, so the row appears with the
       subject and the drop time (no sender, and `sortDate` falls back to
       `highlightedAt`), and the card scrolls to it. A provider with no
       usable `message:` URL (a Finder `.eml` file) waits for its file, the
       only source of its Message-ID; a local file is fast.
    2. **Late.** For a fast message, the card waits for the `.eml` apart
       from the drop chain, so a second drop shows its own rows without
       waiting for this file. When the file arrives and parses to the SAME
       Message-ID, the card appends a link to the contact's write chain that
       writes the email again with the file's headers. The overlay rule (see
       "Writing") keeps the first `highlightedAt` and takes the sender and
       the sent date, so the row fills in; it can move in the section, which
       sorts by the sent date. A file that fails, never arrives, or holds
       another Message-ID changes nothing.
    3. **No revive.** A remove writes a tombstone and a highlight revives a
       tombstone, so the late link first reads the contact's highlighted
       emails and writes only when the email is still there: a row the user
       removed while the file loaded stays removed. A remove is not part of
       the write chain, so a remove that lands between that read and the
       write is still revived; the window is one sidecar read.
- **The log for a hand test** (channel `app.mail-drop`, at info, so the
  default log floor keeps it):
    - `list drop target installed` (with the search `attempt`) once the
      target finds the list, or `list drop target not found` after the last
      attempt. Without an `installed` line, the card has no Mail drop
      interaction.
    - `mail drop session`, once per drag session that UIKit asks the target
      about, also when the answer is no: `items` (the item count), `types` (each
      provider's `registeredTypeIdentifiers`, as `0: a b | 1: c`), and
      `canHandle`. This line shows what Catalyst exposes for a Mail drag.
    - On a drop, `mail drop provider` for each provider, then
      `highlighted email drop` (channel `app.highlighted-email`) with the
      `messages`, `usable`, `lateFiles` (messages whose `.eml` is still
      loading), and `contactValues` counts.
    - `mail drop load`, once per finished load\[^loadLog]: the provider
      `index`, the `kind` (`file`, `url`, or `text`), `ok` (whether it gave a
      value), `ms` (milliseconds since `startLoading`), and `error` as
      `domain#code` (`none` when there is no error). It shows which load is
      slow, and whether the `.eml` arrives at all.
    - `highlighted email file headers` (channel `app.highlighted-email`),
      once per late `.eml` of a fast message, with a fixed `result`:
      `written`, `removed` (the no-revive check skipped it), `no file` (the
      load failed), or `other message` (a different Message-ID, or none).

  None of these lines holds a subject, an address, a file name, or a URL.
- **Mapping:** `HighlightedEmail.init?(headers:highlightedAt:)` builds each
  email, with `highlightedAt` set to the time of the drop\[^mapping]. A message
  with no usable Message-ID is skipped; a drop with none adds no highlighted
  email.
- **Writes are serial.** The task awaits `highlightEmail(_:for:)` for each
  email in turn, as the caller precondition above requires, then adds the
  drop's contact values (see "Dropping a web, mailto:, or tel: link"). A
  second drop on the same card waits for the first drop's writes before it
  starts its own. A late `.eml` write (see "Two phases") joins the same
  chain when its file arrives. A failed write is logged (never the subject
  or an address) and the loop goes on to the next message.
- **The card scrolls to the drop.** When a drop's writes finish, the view
  keeps the ids it wrote; when the section shows one of them, the card
  forgets the ids and scrolls (animated, row centered) to the first of them
  in section order\[^scroll]. The section re-reads run apart from the
  writes, so the rows can show before or after the writes finish; both cases
  scroll. In a normal drop the row and the scroll target arrive in the same
  update, so the scroll runs on a later main-actor turn. A newer drop
  replaces the ids of an older one that has not scrolled yet.
- **The monogram's photo drop from another app is not measured.** It is a
  view-level SwiftUI `.onDrop(of: [.image])` on the monogram in the header
  row, not one of the `List`'s own row drops (`.onInsert`, `.onMove`).
  SwiftUI serves a view-level drop from its own drop interaction on the root
  hosting view, above the list (seen in a hosted test on macOS
  27\[^bridge], and described in the workaround source). Before this target,
  FB24490454 broke it on Catalyst: the list's built-in interaction took every
  session from another app, images too, and refused it, so an image dragged
  from Finder onto the monogram did not drop (seen in a hand test). The
  `.onDrop` code did not change, but the route did: while this target is
  enabled, the built-in interaction is removed, and this target refuses an
  image or file drag that has no Mail type, so its interaction does not
  claim that session and UIKit can offer it to another interaction, such as
  the root one. Whether an image dragged from another app now reaches the
  photo drop is not measured.

### Dropping a web, mailto:, or tel: link

A dropped link that is not a Mail message adds a value to the contact's
Contacts record, not a highlighted email: an `http`/`https` link a website
row (`urlAddresses`), a `mailto:` link an email row (`emailAddresses`), and a
`tel:` link a phone row (`phoneNumbers`). It uses the same drop target as an
email (see "Dropping an email"). Which types a link dragged from another
app, such as Safari, exposes on Catalyst is not measured; the
`mail drop session` log line shows them.

On the card:

- **Which providers are contact values.** `MailDropReader.read(_:)` returns
  the drop's messages and contact values, each in provider order\[^read]. A
  provider whose loads yield a Message-ID (a `message:` URL, else the
  `.eml`) is a message. Any other provider whose URL is `http`, `https`,
  `mailto`, or `tel`, in any case, is a contact value, passed on whole. Any
  other provider adds nothing.
- **One call per drop, after the emails.** In the same task chain as the
  emails (`highlightDropTask`), after the drop's email writes, the card
  passes ALL of the drop's contact values to ONE
  `addContactValues(from:for:)` call\[^valueDrop], as the caller
  precondition below requires. The call is for the contact the drop landed
  on: the id is taken in `performDrop`, like the emails' id.
- **The card re-loads.** When the call added at least one row, the card runs
  `loadContact(preferFresh: true)`. It must: the website, email, and phone
  rows render from the card's `contact` state, and nothing sets that state
  when the repository posts `.contactsRepositoryDidReload` — the card's
  observer re-reads only the two email sections\[^coarse]. A LinkedIn import
  and an inline edit save re-load the same way. A drop with nothing new
  does not re-load. The card does not scroll to the new row; the scroll
  after a drop is for highlighted emails only.
- **Errors.** A failed call (a gone contact, a failed save) is logged as
  `add contact values failed` (channel `app.highlighted-email`) and recorded
  with `service.recordError`. The card puts no URL, address, or number in
  either.

`ContactsRepository.addContactValues(from:for:)` takes `[URL]` and a
`ContactID` and returns `AddedContactValues`, the rows it added to each
field (`emailAddresses`, `phoneNumbers`, `urlAddresses`, and their
`total`)\[^addValues]. Each URL goes by its scheme, in any case:

- **`http` / `https`:** the URL's `absoluteString` is a website.
- **`mailto`:** the part before any `?` is percent-decoded first, then split
  at `,` and `;`, so a list encoded whole (`a%40x.com%2Cb%40y.com`, as
  `encodeURIComponent` writes it) and an Outlook-style `;` list each give
  one address per entry. An entry in display-name form
  (`Jane Doe <jane@x.com>`) gives the part inside its last `<…>`. The
  trimmed result is kept only when it is a bare address: exactly one `@`
  with text on both sides, and no whitespace, `<`, `>`, `,`, `;`, or `"`. A
  quoted name with a comma (`"Doe, Jane" <jane@x.com>`) splits in two; the
  half with the brackets still gives the address, and the other half gives
  none. The query (`subject=`, `cc=`, `body=`, …) is ignored, even one that
  names an address. A list that does not percent-decode gives nothing.
- **`tel`:** the part before any `;` parameter (`;ext=`, `;phone-context=`,
  …), percent-decoded and trimmed, is a phone number, kept as written:
  Contacts formats it. In the `tel://5550100` form the number is the URL's
  host; it reads the same as `tel:5550100`. A number with no digit is
  skipped.
- **Any other scheme** (`message:`, `file:`, `ftp:`, `sms:`, …) is ignored,
  not an error. An input with no value returns zero and does not read the
  contact.

The merge is the LinkedIn import's for each field\[^importValues]:

- **No duplicates.** A value the contact already has, or one repeated in the
  input, is skipped. Emails compare by `emailDedupKey` (trimmed and
  lowercased). Websites compare by `urlDedupKey`: lowercased, with no
  scheme, no leading `www.`, and no trailing slash, so
  `https://www.example.com/` matches a stored `example.com`\[^dedup]. The
  first spelling in the input wins, and input order is kept.
- **Phone numbers compare as E.164 digits.** A `tel:` link is usually E.164
  (`+15550100123`), while a stored number often has no country code. So
  `phoneDedupKey` parses each number with PhoneNumberKit, through the
  shared `PhoneNumberDisplayFormatter`, reading a number with no country
  code in the device's region, and compares the E.164 digits WITHOUT the
  `+`, plus `;ext=` and the digits of any extension\[^phoneKey]. On a US
  device a dropped `+1 555 010 0123` matches a stored `(555) 010-0123`, and
  every spelling of one extension (`x7`, `ext. 7`, `,7`, `,,7`) is the same.
  The first of these parses that succeeds gives the key:
    1. In the device's region, with PhoneNumberKit's number-type check: a
       valid national number, or any number written with a `+`.
    2. When there is no leading `+`: `+` and the string, with the type
       check. So a full number written with its country code but no `+`
       (`1-212-555-0123`) reads as that country's number. Without this
       step, a parse with no type check reads it as a long national number
       on a DE, IN, or BR device, among others, and it would not match
       `+1 212 555 0123`.
    3. In the device's region, without the type check, so a number in a
       range the metadata does not list (a fictional 555 number) still
       compares by its country and digits.
    4. Else the digits only. Because a parsed key has no `+`, a full number
       that no step parses (`1-555-010-0199` on a GB device) still matches
       the same number written with a `+`.

  The limit: a full number with no `+` whose digits are ALSO a valid
  national number of the device's region (`1-212-555-0123` on an AT
  device) reads as national in step 1, so it does not match the same
  number written with a `+`. The LinkedIn import uses the same key.
- **Default label.** A new row has an empty label, so Contacts gives it its
  default label.
- **One save, and only on a change.** Nothing new: no Contacts save and no
  stamp. Something new: ONE `saveContact` for all three fields, then a
  best-effort Last Modified stamp, so the contact sorts as edited. The stamp
  is a sidecar write, so it mints the GuessWho ID of a contact that has
  none.
- **A gone contact throws.** An id that does not resolve, or a contact with no
  Contacts record, throws `ContactStoreError.contactNotFound`, like the
  LinkedIn import. A failed save is rethrown.
- **Caller precondition: one write at a time per contact.** A caller awaits
  each call before it starts the next write to the same contact — this
  method, `highlightEmail(_:for:)`, or any other card or sidecar write. One
  drop passes all of its URLs in ONE call, and a second drop on the same card
  waits for the first, the way the card chains its drops\[^valueDrop]. The
  method reads the card and then saves the WHOLE card back: a save writes
  every `emailAddresses`, `phoneNumbers`, and `urlAddresses` row from the
  saved value\[^save]. So two calls that overlap can both read the same
  rows, and the later save wins. **A row the first call added is lost**,
  although both calls report it as added. An overlap with a write that
  mints the contact's identity has the reconcile risk that the
  `highlightEmail(_:for:)` precondition names (see "Repository surface").
- **Notifications.** The save refreshes the cached record and posts
  `.contactsRepositoryDidReload` (`contactDataChanged: true`); a stamp that
  succeeds posts it again\[^valuePosts]. No highlighted-email notification
  is posted.
- **Logging** records counts per kind only, never an address, a number, or
  a URL.

### The section

The contact card shows a **Highlighted Emails** section directly above Recent
Email\[^section]. It lists every highlighted email in the repository order,
with no cap, and is hidden when there are none. A row has the Recent Email
look: the subject (or "(No subject)"), and a caption of the sender name (else
the sender address, else nothing) and the date — `sentAt`, else
`highlightedAt`\[^row].

- **Tap** opens the message in Mail.
- **Context menu:** "Open in Mail", and a destructive "Remove" that calls
  `removeHighlightedEmail(id:for:)`\[^removeUI]. The row goes away when the
  change notification re-reads the section; the view does not edit its list
  in place.

The `message://` link is **best effort**. Both email sections build it in one
place\[^link]: the normalized Message-ID, wrapped in `<` `>`, through
`MailMessageID.mailDeepLink(for:)`. That returns nil for an ID that is not
safe in a URL, and Apple does not document the scheme, so Mail may not find
the message (for example, when Mail no longer has it locally). A row
with no link still shows, has no tap action, and still offers "Remove".

### Loading and refresh

The full contact load reads highlighted emails in parallel with mail
activity\[^load]. The card then re-reads only this section:

- on `.contactsRepositoryHighlightedEmailsDidChange` when any token in its
  `contactIDs` resolves to this contact. Every token is resolved through the
  repository before the compare, so a post for a write that minted the
  contact's identity matches a card that still holds its pre-mint
  token\[^scoped];
- on `.contactsRepositoryDidReload`, after a 150 ms debounce, as the fallback
  for coarse watcher deliveries\[^coarse]. Highlighted emails and Recent Email
  each keep their own debounce task, so a scoped change for one section
  cancels only its own fallback.

Each re-read is newest-wins\[^reload]: a drop of N messages posts N changes,
and the re-reads can finish out of order, so only the most recently started
read may publish. The full load uses the same gate, so a re-read that started
later wins over it.

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
\[^save]: [CNContactStoreAdapter.save → apply(\_:to:) sets phoneNumbers, emailAddresses, and urlAddresses from the saved value](../Sources/GuessWhoSync/CNContactStoreAdapter.swift:CNContactStoreAdapter.apply)
\[^drop]: [ListMailDropTarget / MailDropInteractionDelegate / ContactDetailView.addDroppedItems(\_:)](../App/GuessWho/Support/ListMailDropTarget.swift:ListMailDropTarget)
\[^install]: [ListDropInstallerView.ownListCollectionView() / update(isEnabled:)](../App/GuessWho/Support/ListMailDropTarget.swift:ListDropInstallerView.ownListCollectionView)
\[^bridge]: [ListMailDropTargetTests.aViewAboveTheListKeepsADropInteractionThatIsNotOurs](../App/GuessWhoTests/ListMailDropTargetTests.swift:ListMailDropTargetTests.aViewAboveTheListKeepsADropInteractionThatIsNotOurs)
\[^accept]: [MailDropReader.canAccept(\_:) / isMailMessage(\_:)](../App/GuessWho/Support/MailDropReader.swift:MailDropReader.canAccept)
\[^read]: [MailDropReader.read(\_:) / PendingItem.item()](../App/GuessWho/Support/MailDropReader.swift:MailDropReader.read)
\[^progress]: [MailDropInteractionDelegate.dropInteraction(\_:performDrop:)](../App/GuessWho/Support/ListMailDropTarget.swift:MailDropInteractionDelegate.dropInteraction)
\[^twoPhase]: [MailDropReader.DroppedMessage / PendingItem.item() / ContactDetailView.addLateFileHeaders / writeLateFileHeaders](../App/GuessWho/ContactDetailView.swift:ContactDetailView.addLateFileHeaders)
\[^loadLog]: [MailDropReader.LoadLog](../App/GuessWho/Support/MailDropReader.swift:MailDropReader.LoadLog)
\[^scroll]: [ContactDetailView.highlightScrollTarget / ScrollToHighlightedEmailModifier](../App/GuessWho/ContactDetailView.swift:ScrollToHighlightedEmailModifier)
\[^mapping]: [HighlightedEmail.init?(headers:highlightedAt:)](../Sources/GuessWhoSync/HighlightedEmail.swift:HighlightedEmail.init)
\[^valueDrop]: [ContactDetailView.addDroppedItems(\_:) / addDroppedContactValues(\_:for:)](../App/GuessWho/ContactDetailView.swift:ContactDetailView.addDroppedContactValues)
\[^addValues]: [ContactsRepository.addContactValues(from:for:) / AddedContactValues](../Sources/GuessWhoSync/ContactsRepository.swift:ContactsRepository.addContactValues)
\[^importValues]: [ContactsRepository.applyLinkedIn — the `.emails`, `.phones`, and `.websites` branches](../Sources/GuessWhoSync/ContactsRepository.swift:ContactsRepository.applyLinkedIn)
\[^dedup]: [ContactsRepository.emailDedupKey / urlDedupKey / newValues(\_:notIn:key:)](../Sources/GuessWhoSync/ContactsRepository.swift:ContactsRepository.urlDedupKey)
\[^phoneKey]: [ContactsRepository.phoneDedupKey → PhoneNumberDisplayFormatter.comparisonKey(for:region:), which also holds the digits fallback](../Sources/GuessWhoSync/PhoneNumberFormatting.swift:PhoneNumberDisplayFormatter.comparisonKey)
\[^valuePosts]: [ContactsRepository.saveContact → refreshContact(localID:) → postDidReload; stampTimestamps posts its own reload](../Sources/GuessWhoSync/ContactsRepository.swift:ContactsRepository.stampTimestamps)
\[^section]: [ContactDetailView.highlightedEmailsSection](../App/GuessWho/ContactDetailView.swift:ContactDetailView.highlightedEmailsSection)
\[^row]: [ContactDetailView.highlightedEmailLabel / mailMessageLabel](../App/GuessWho/ContactDetailView.swift:ContactDetailView.mailMessageLabel)
\[^removeUI]: [ContactDetailView.highlightedEmailRow / removeHighlightedEmail(\_:)](../App/GuessWho/ContactDetailView.swift:ContactDetailView.highlightedEmailRow)
\[^link]: [MailMessageLink.url(forNormalizedMessageID:)](../App/GuessWho/ContactDetailView.swift:MailMessageLink.url)
\[^load]: [ContactDetailView.loadContact — async let fetchedHighlightedEmails](../App/GuessWho/ContactDetailView.swift:ContactDetailView.loadContact)
\[^scoped]: [ContactDetailView.highlightedEmailsDidChange / mailSectionContactID(changedBy:contactIDsKey:)](../App/GuessWho/ContactDetailView.swift:ContactDetailView.mailSectionContactID)
\[^coarse]: [ContactDetailView.repositoryDidReloadForMailSections](../App/GuessWho/ContactDetailView.swift:ContactDetailView.repositoryDidReloadForMailSections)
\[^reload]: [ContactDetailView.reloadHighlightedEmails(for:)](../App/GuessWho/ContactDetailView.swift:ContactDetailView.reloadHighlightedEmails)
