# Apple Mail extension & the Mail handoff files

This document is the source of truth for the **GuessWho Mail extension** — a
MailKit app extension for Apple Mail on the Mac — and for the two files it
shares with the app through the App Group container: the **contact cache**
the app publishes and the **incoming-message journal** the extension appends
and the app drains. Read it before touching the extension target, the files'
formats, or the code that writes or drains them.

## What it does

- **Highlights mail from favorite people — currently switched off** (`MessageActionHandler.flagsHighlightedSenders` is `false`; the flag logic and its tests remain, and journaling is unaffected). When it is on, for each newly received message, the extension looks the sender up in the contact cache. If any matching contact is a favorite, belongs to a favorite group, works at a favorite organization, or belongs to a favorite department, the extension flags the message. The flag color follows the reason (`MailFlagColor`): blue for a favorite contact, green for a favorite group member, orange for a favorite organization or department member, and Mail's default flag color for a reason this build does not recognize. When a sender has several reasons, the first in that order wins. The extension sets the flag only when the message downloads and never changes it afterward; that Mail's Flag menu clears it is expected but unverified.
- **Records mail from known people.** For every message whose sender is in the cache, the extension appends one metadata-only entry to the journal. The app records it under **Recent Email** on every matching contact and advances Last Interaction.
- **Shows who you are writing to.** In a compose window, a toolbar button (tooltip **Recipient details**) opens a popover listing each recipient with a photo or initials, name, title, and organization. One person appears once, even when the window holds two of their addresses. Clicking a known row slides in a detail page (photo, name, title, organization, emails, phone numbers, birthday) with a **Back** button and, when the contact has a GuessWho ID, a **GuessWho** button that opens the contact in the app.
- **Adds a recipient you don't have yet.** A recipient the cache does not know gets a row with the name Mail gave for them and their address, or only the address and **No contact details** when there is no name. When the cache was fully readable and the recipient is a valid address, the row has an **Add Contact** button (`person.crop.circle.badge.plus`). It brings GuessWho forward with the new-contact editor filled in with the name and address, so the user can add what else they know and save; Cancel adds nothing. When the cache can't be read ("Contact details aren't available right now."), there is no button, because the extension can't tell whether the person is already a contact. Unknown rows don't open a detail page. Whether Mail's compose session gives a display name at all is unverified (see *Display names from Mail*).

## The pieces

| Piece | Where | Role |
| ----- | ----- | ---- |
| Extension target | `App/GuessWhoMailExtension/` | Native macOS app extension (`com.apple.email.extension`). Principal class `MailExtension` vends process-wide handlers. |
| Message actions | `MessageActionHandler.swift` | `MEMessageActionHandler`: highlight + journal on each received message. |
| Compose popover | `ComposeSessionHandler.swift`, `RecipientsModel.swift`, `RecipientsView.swift`, `RecipientsViewController.swift` | `MEComposeSessionHandler` + a SwiftUI list hosted in an `MEExtensionViewController`. |
| Shared format | `App/GuessWhoMailShared/` | Foundation-only code compiled into both the extension and the app: address normalization, cache and journal formats and stores, Message-ID handling, and App Group lookup. |
| App bridge | `App/GuessWho/Support/MailBridgeController.swift` | Publishes the contact cache, drains the journal, and records contact mail activity. |
| Shared tests | `App/GuessWhoTests/MailHandoffTests.swift` | Cache, journal, bounds, concurrency, forward compatibility, display names, and the wake URLs. |
| Bridge tests | `App/GuessWhoTests/MailBridgeControllerTests.swift` | Projection, normalization, thumbnail budget, no-op writes, and newer-format preservation. |

## Target and embedding

- **Native macOS, not Catalyst.** MailKit is unavailable to Mac Catalyst, so
  `GuessWhoMailExtension` builds with `SDKROOT = macosx`
  (`App/Config/GuessWhoMailExtension-Shared.xcconfig`), macOS 14 floor,
  Swift 6.
- **Embedded only in the Mac Catalyst app**, under
  `GuessWho.app/Contents/PlugIns/`. Both the *Embed Foundation Extensions*
  build file and the app's target dependency carry
  `platformFilter = maccatalyst`, so iOS builds neither build nor ship it.
- **No Swift packages.** A macOS target that links the app's package graph in
  the same `xcodebuild` as the Catalyst app collides in archive planning (the
  reason `guesswho-cli` is built by a nested `xcodebuild`). The extension uses
  only Foundation, AppKit, SwiftUI, and MailKit, and logs through `os.Logger`
  (subsystem `com.milestonemade.guesswho.mail`) instead of GuessWhoLogging.
- **Identity.** Bundle id `com.milestonemade.guesswho.mail` in both
  configurations; display name "GuessWho" (Release) or "GuessWho Debug"
  (Debug). Because Debug and Release share the bundle id, PlugInKit registers
  only one copy when both builds are installed; the display name shows which
  one Mail is using.
- **Entitlements.** App Sandbox (Mail loads only sandboxed extensions) and the
  App Group — nothing else: no Contacts, Calendars, iCloud, or network.
  MailKit capabilities are declared in `Info.plist`
  (`MEExtensionCapabilities`: `MEComposeSessionHandler`,
  `MEMessageActionHandler`), with the compose button's icon (`ToolbarIcon` in
  the extension's asset catalog) and tooltip under `MEComposeSession`.
- **MailKit calls "main-actor" protocols off the main thread.** `MEExtension`
  and `MEComposeSessionHandler` are declared `@MainActor`, yet crash reports
  show MailKit creating the principal object (`MailExtension.init`) and
  delivering `annotateAddressesForSession` and `mailComposeSessionDidEnd` on
  its NSXPC queue. Under Swift 6 a main-actor-isolated `init` or witness
  checks its executor at entry and traps there (`_dispatch_assert_queue_fail`
  in the crash report, which also blanks the compose popover). So
  `MailExtension` is `nonisolated` (its handler factories as a precaution),
  and `ComposeSessionHandler`'s annotate and begin/end methods are
  `nonisolated` and hop to the main queue for per-window state.
  `viewController(for:)` has been seen on the main thread and stays isolated.
- **Mail sizes the compose popover when it presents it.** The popover took
  the view's preferred size at presentation: an asynchronous first lookup
  left it at the loading placeholder's height with the rows clipped. Whether
  Mail follows a later `preferredContentSize` change is unverified, so
  `viewController(for:)` fills the model synchronously
  (`RecipientsModel.showNow`) before it returns the view controller; keep
  that first lookup synchronous.
- **The detail page changes the popover's size.** The list is sized from its
  row count, and the detail page from its measured content (header, divider,
  and the scrolling content's natural height). Both pages share one maximum
  height, `RecipientsView.maximumHeight` (420pt), and scroll past it. The
  measured height is kept with its row's ID and used only while that row is
  open, so opening another row keeps the list's height until its page
  reports. Opening a row during the Back slide-out (0.25s) can reuse the
  outgoing page, which doesn't report its unchanged height again, so two
  rules keep the page from sticking at the list's height. Each row's page
  has its own view identity (`.id(row.id)`), so a different row is a new
  view that reports. The same row still reuses its page, so the stored
  height is kept, not cleared, on Back and sizes that page. Don't replace
  the stored height with "clear on open": that brings the stuck page back
  for the same row. `RecipientsView` reports
  each height change through `onSizeChange`, and `RecipientsViewController`
  sets its own `preferredContentSize` from it. Don't go back to the child
  `NSHostingController`'s `.preferredContentSize` sizing option: it changes
  the child's `preferredContentSize` without a KVO notice and without calling
  the parent's `preferredContentSizeDidChange(for:)`, so the extension kept
  reporting the list's size and Mail left the detail page clipped at that
  height. The hosting controller keeps its default sizing options, so its
  view is also constrained to the SwiftUI frame; setting
  `[.preferredContentSize]` alone would remove those constraints. The
  extension therefore sends two size signals (the constraints and
  `preferredContentSize`), and a hand-check in Mail can't tell which one Mail
  follows. Whether Mail resizes the popover for them is unverified:
  hand-check it, and if Mail keeps the first size, give both pages one fixed
  height.
- **The GuessWho and Add Contact buttons are wake URLs.** The extension opens
  them with `NSWorkspace` (`GuessWhoAppLink`), and Launch Services brings the
  app forward. The scheme is the app's per-configuration wake scheme
  (`guesswho-linkedin[-debug]`), read from the extension's own
  `GuessWhoLinkedInURLScheme` Info.plist key, fed by
  `GUESSWHO_LINKEDIN_URL_SCHEME` in the extension's xcconfigs (keep them equal
  to the app's). Both URLs are built and parsed in
  `GuessWhoMailShared/MailContactLink.swift`, and the app's scene delegate
  routes each host to its handler (Catalyst only):
  - `<scheme>://open-contact?id=<GuessWho ID>` (`MailContactLink`) — the
    **GuessWho** button. `handleOpenContactWake` waits for the first contacts
    load, selects the People row, and shows the detail. The ID is the bare
    GuessWho UUID, never a Contacts identifier.
  - `<scheme>://new-contact?email=<address>[&name=<display name>]`
    (`MailNewContactLink`) — the **Add Contact** button. The URL carries the
    normalized address and, when Mail gave one, the trimmed display name,
    cut to 256 UTF-8 bytes at a whole character; the name is left out when it
    is only the address again. Any app on the Mac can open this URL, so the
    app parses every value as untrusted: it normalizes the address again
    (refusing the URL when that fails) and applies the name rules again.
    Nothing more is needed, because the values only pre-fill an editor the
    user must save. `handleNewContactWake` waits for the first contacts load.
    If a contact already lists the address (the cache can lag a contact
    created moments ago, or the user clicks Add again after saving), that
    contact opens as for `open-contact`. Otherwise it presents the standard
    new-contact editor (`ContactEditView`) as a sheet, seeded by
    `Contact.newPersonSeed(name:email:)` — the same name split as an event
    invitee's Add Contact. Save creates a brand-new contact and then selects
    it in People with its detail showing; Cancel creates nothing. A second
    click while the first editor is still open is not caught: it presents a
    second editor over the first.
- **Display names from Mail.** `MEEmailAddress.rawString` can hold a display
  name (`"Jane Doe" <jane@example.com>`); `MailAddressNormalizer.displayName`
  takes the text before the last `<`, removes one pair of surrounding
  quotes, and unescapes `\"` and `\\`. It is best effort, not an RFC 5322
  parser. Whether Mail's compose session puts a display name in `rawString`
  at all is unverified; when it doesn't, unknown rows and the editor have
  only the address.

## App Group and the `Mail/` directory

Both files live in `<App Group container>/Mail/`. The App Group is the app's
Mac Catalyst group, `<TeamID>.com.milestonemade.guesswho` — Debug and Release
share it; it is **not** the CLI/MCP group. The extension's entitlement and its
`GuessWhoAppGroup` Info.plist value both expand from `GUESSWHO_APP_GROUP` in
its xcconfig, so they can't drift.

`MailHandoffContainer` resolves the directory **only** from the running
bundle's `GuessWhoAppGroup` Info.plist value; there is no hardcoded fallback.
On macOS, `containerURL(forSecurityApplicationGroupIdentifier:)` returns a path
whether or not the process is entitled to the group, so a nil result
effectively means the Info.plist key is missing. A missing or wrong
entitlement shows up later, as a permission error from the first read or
write.

The App Group container is local to this Mac; neither file syncs.

| File | Writer | Reader | Format |
| ---- | ------ | ------ | ------ |
| `Mail/contact-cache.plist` | app (only) | extension | binary property list |
| `Mail/incoming-messages.jsonl` | extension appends; app claims and settles | app | JSON Lines |

Every read and write of either file is one `NSFileCoordinator` claim, and
every change replaces the file atomically inside that claim, so neither
process ever sees a torn file and no read-modify-write interleaves with
another (`MailFileCoordination`).

## Email address normalization

`MailAddressNormalizer.normalize(_:)` is the one normalization both sides use:
the app to key the cache, the extension to look senders and recipients up. It
accepts a bare address, a display-name form (`"Name" <local@domain>`), or a
`mailto:` string; trims, lowercases the whole address, and drops a trailing
root dot. It rejects anything without exactly one `@`, with an empty side,
with whitespace, control characters, or angle brackets, or longer than 320
UTF-8 bytes. A key built any other way silently never matches.

## The contact cache (`contact-cache.plist`)

`MailContactSnapshot`: `version`, `generatedAt`, and `summariesByAddress` — a
dictionary from normalized address to every `MailContactSummary` carrying that
address (two cards can share an address; "any summary highlighted" means
highlighted). A summary holds `displayName`, optional `organization`,
`jobTitle`, and `thumbnail` data, and a set of `highlightReasons`. For the
popover's detail page it also holds the contact's GuessWho ID (`contactID`,
nil until the app has given the card one), its `emailAddresses` and
`phoneNumbers` (each `MailLabeledValue`, the label already turned into plain
text by the app so the extension needs no Contacts framework), and a
`birthday` display string. These four decode as absent when an older app wrote
the cache. Build a snapshot with `add(_:forAddresses:)`, which normalizes
every key; publish it with `MailContactCacheStore.write(_:)`.

**Highlight reasons are an open set.** `MailHighlightReason` is a string
wrapper, not an enum: `favoriteContact`, `favoriteGroupMember`, and
`favoriteOrganizationMember` today. A reason an older extension doesn't
recognize still decodes and still counts as highlighted.

**Version rules.** Bump `MailContactSnapshot.currentVersion` only for a
breaking shape change (a field renamed, retyped, or removed). Adding an
optional field or a highlight reason is not breaking. Every version must keep
a top-level `summariesByAddress` dictionary keyed by normalized address.

**Reading.** `MailContactCacheStore.read()` returns nil when nothing has been
published, `.current(snapshot)` for a format it reads fully, and
`.newerFormat(version:knownAddresses:)` for a breaking newer format whose
address index is still readable. It throws `unsupportedVersion` when even the
index isn't readable, and on I/O or decode errors. It remembers its last
outcome — contents or decode failure — for one on-disk version of the file
(inode, size, modification date), so a burst of messages decodes the file
once; plain I/O errors are retried on the next read.

With a `.newerFormat` cache, the extension still journals known senders but
flags nothing, and the compose popover shows addresses only.

**Publisher bounds.** The app projection accepts at most 256 KiB of thumbnail data from one contact and at most 8 MiB across the snapshot, charging repeated bytes once per normalized address because the plist stores one summary per address key. Contacts remain in the cache when their thumbnail is omitted. These limits keep compose lookup bounded without changing sender recognition or highlight reasons.

## The incoming-message journal (`incoming-messages.jsonl`)

### Entries

`MailIncomingMessage` — metadata only, never any part of the body. Every
text field is sender-controlled, so every bound is in **UTF-8 bytes**:

| Field | Source | Bound |
| ----- | ------ | ----- |
| `version` | this build | — |
| `sender` | normalized From address | ≤ 320 bytes (else `append` throws `invalidEntry`) |
| `subject` | Subject, trimmed; nil when empty | clipped to 1,024 bytes at the last whole character (grapheme cluster) that fits — valid UTF-8, combining marks kept with their base; nil if even the first character doesn't fit |
| `receivedAt` | Mail's received date (now, when absent) | — |
| `messageID` | canonical `<…>` Message-ID; the de-duplication key | ≤ 986 bytes (else `invalidEntry`) |
| `messageURL` | best-effort `message://` link, may be nil | dropped when over 4 KiB |

`append` re-checks all four bounds (the fields are mutable), then refuses
any entry whose **encoded line** exceeds 16 KiB (`maximumLineByteCount`,
error `entryTooLarge`) before it touches the file. That bounds what a
single entry can evict rather than preventing eviction: when the file is at
its byte cap, an accepted entry still evicts the fewest oldest unclaimed
lines that make room for it — whole lines, so about its own size and at
most about two line caps (32 KiB) of backlog. Every entry
within the field bounds — even one built from the characters JSON escapes
most expensively — encodes under the line cap
(`worstCaseEntryFitsTheLineCap`), so the cap is a backstop.

Bump `MailIncomingMessage.currentVersion` only for a breaking shape change.

### Line format

One JSON object per line:

```json
{"claim":{"claimedAt":780000000,"token":"…UUID…"},"entry":{…MailIncomingMessage…}}
```

`claim` is absent on an unclaimed line. Its shape (`token` UUID string,
`claimedAt` seconds since 2001) is fixed across versions, so every build
reads every other build's claims. Claiming, renewing, and releasing rewrite
**only** the `claim` member of a line's JSON object; every other member —
including keys this build doesn't know, inside `entry` or beside it — is
written back as read. A line whose `entry` this build can't decode (a newer
entry version, or damage) is never claimed and is carried byte-for-byte
through every claim, settle, and append; its `messageID` still counts for
de-duplication. Like any unclaimed line, though, it can be evicted by
retention when an append needs room — preserved from rewrites, not from
capacity limits.

### Appending (extension)

`append(_:)` adds the entry unless a line with the same Message-ID is already
in the file — claimed or not — then posts the change notification. Once the
app acknowledges an entry it is gone, so a later delivery of the same message
is appended again: **the app's store must also de-duplicate by Message-ID.**

### Retention

`append` keeps the file within 2,000 lines and 2 MiB (`maximumEntryCount`,
`maximumByteCount`) by evicting the oldest lines that no live claim holds.
**Live claimed lines are never evicted.** If the new entry can't fit even
then, it is dropped (`.droppedForCapacity`) and the file is left unchanged;
the extension logs that and still applies the highlight.

The caps are enforced only at append. Claiming and renewing add claim
metadata (under 100 bytes a line) without re-checking them, so a file that
is mostly claimed lines can briefly exceed `maximumByteCount` by that
metadata; the next append trims unclaimed lines again.

### Draining (app): the claim lifecycle

1. **Claim.** `claimEntries(limit:)` atomically marks up to `limit` (default 50) of the oldest entries that no live claim holds with a fresh token and returns them as a `Claim`. A second claimer — for example a Debug and an /Applications copy of the app — gets only entries nobody holds.

2. **Work, renewing as needed.** A claim is live for `claimLease` (5 minutes) from its last claim or `renew(_:)`. The app renews the active batch and every failed entry it is deferring while later batches drain.

3. **Settle, whole or by subset.** `acknowledge(_:messageIDs:)` removes entries that were stored or whose sender is proven absent after the current contacts revision was successfully published. `release(_:messageIDs:)` returns failures and temporarily unmatched entries for a later retry. Settling by Message-ID subset keeps one entry that cannot be stored from pinning or replaying the rest of the batch.

4. **Fencing.** `renew`, `acknowledge`, and `release` touch only lines that still carry the claim token. Each returns a `ClaimOutcome` that puts every Message-ID asked about in exactly one bucket:

    - `applied` — held by this claim; the call acted on it.
    - `lost` — in the journal but held by a different claim token: this claim lease lapsed and another claimer took it. A claimer with `lostOwnership` must treat those entries as someone else’s.
    - `settledOrMissing` — held by no claim: already acknowledged or released, evicted, or never present. A whole-claim settle after earlier subset settles reports the caller work here, not as lost.

   A lapsed claim whose entries nobody retook still settles them.

5. **Crash recovery.** A claim that is never settled expires after the lease, and its entries become claimable again.

### Change notification

After each successful append the journal posts the Darwin notification
`<App Group id>.mail.incoming-journal` (`MailJournalChangeNotification`), so a
running app can drain promptly; `MailJournalChangeNotification.Observer`
subscribes to it. Darwin notifications carry no payload and may coalesce: an
observer treats one as "the journal may have changed" and claims whatever is
there. Draining on activation remains the fallback.

## App bridge lifecycle

`MailBridgeController` is owned by `GuessWhoAppDelegate` on Mac Catalyst, so one instance serves every window. At launch it waits for the contacts repository to finish its initial load, loads the group identity cache, then publishes and drains. Contact-data reloads, group-membership changes made in this app, favorite changes made in this app, and app activation schedule a debounced publication; presentation-only reloads do not. The Contacts change-history request deliberately sets `includeGroupChanges = false`, so membership edits made in Contacts.app or synced from another device update Mail highlights the next time GuessWho activates. A favorite change synced from another device is likewise picked up on the next repository refresh or app activation because `FavoritesListStore` intentionally does not watch remote writes directly. Darwin journal notifications, repository recovery, and activation trigger a single-flight drain. An incomplete or failed group load posts a presentation-only reload, preserves existing Mail highlights, and is retried through the 30-second recovery backoff when a favorite group needs it, or on activation, rather than forming a reload loop.

The published snapshot includes every email-bearing contact so Mail can recognize compose recipients and journal known senders. Highlight reasons are projected from favorite contacts, favorite organization members, favorite department members, and favorite group members. Favorites and App Group file reads run off the main actor. Contacts group reads and durable group-identity enumeration are revision-checked and error-aware, and the last projection gate checks contact, membership, hierarchy, load state, and reload outcome before entering the cache publication transaction. A failed favorites, groups, group identities, contacts, or stale read preserves the previous cache. Newer formats, including a breaking format whose address index this build cannot decode, are never downgraded. Equivalent current snapshots are not rewritten, and a transient cache failure schedules another publication after 30 seconds. Snapshot sorting is computed once per contact on a utility task and compares a fixed-size thumbnail digest rather than the image bytes. Every ordinary contact-data revision invalidates the thumbnail cache because `Contact` has no photo-content revision. The cache is carried forward only when it represented the reported source revision, repository metadata names consecutive before-and-after revisions, and the destination is still current; together those checks prove that only the private identity URL changed between the cached and current revisions. The scan checks cancellation and revisions around every photo fetch. Thumbnails are capped at 256 KiB each and 8 MiB total after charging the bytes once per normalized address; transient photo read failures are retried rather than cached as no photo.

The drainer claims up to ten batches of 50 entries per pass and renews both active and deferred ownership while processing. It builds the contact-address index only after finding work, rebuilds that index if the contact revision changes, uses the same `MailAddressNormalizer` as the extension cache, and records one message against every matching contact. Writes for each contact are awaited sequentially because the first incoming activity can transparently mint the private GuessWho identity URL on its Contacts card; `MailActivity` then de-duplicates redelivery by Message-ID and advances Last Interaction only forward. Stored entries are acknowledged. An unmatched sender is acknowledged only when the current contact revision has been successfully published, proving the extension cache and repository agree that the address is gone, or when the journal entry is at least seven days old; otherwise it is released for retry. Failed entries stay claimed while later batches drain, then are released together and retried after five minutes, so one poison entry cannot pin the backlog or cause a tight loop while a newer cache format is preserved. Claim, renewal, and release failures also schedule retries; a later pass first retries any release that previously failed. Loading or failed repository state never acknowledges an entry. Shutdown best-effort releases live claims, and fencing prevents this process from settling ownership another app copy acquired.

## Privacy

- The extension reads the From address, Subject, received date, and
  `Message-ID` header of received messages (`MEMessage.state == .received`).
  It asks Mail to fetch `Message-ID` (`requiredHeaders`) and never asks for
  the body: it never returns `invokeAgainWithBody` and never reads `rawData`.
- It journals only messages from senders in the contact cache, and only the
  fields above. Unknown senders leave no trace.
- It never annotates compose recipients; the popover only displays what the
  cache holds and the addresses and names Mail gives for the recipients.
- It passes a recipient's address and display name to the app only when the
  user clicks **Add Contact**, and only in the wake URL it gives Launch
  Services. Nothing is written to the App Group, and the app saves nothing
  until the user saves the editor.
- Its log lines carry fixed messages and, for failures, only the error's
  type, `NSError` domain, and code (`LoggedError.fingerprint`) — never an
  error description, file path, coding path, address, or subject.
- Any cache or journal failure leaves the message exactly as Mail delivered
  it.

## The `message://` link is best effort

Apple has never documented Mail’s `message:` URL scheme. Mail has long answered `message://%3C<id>%3E`, but it may change or stop working in any release, and it only finds messages Mail still has locally. `MailMessageID.mailDeepLink(for:)` builds a link only from a syntactically safe Message-ID — exactly one `@`, both sides RFC 5322 dot-atom text in ASCII — and percent-encodes everything but unreserved characters and `@`. The app rebuilds the link from the stored canonical Message-ID both when recording and when opening a Recent Email row; canonicalization preserves the local part but lowercases the domain, so the undocumented lookup remains best effort. It never trusts a persisted URL or a URL supplied by another process. Journaling and activity storage never depend on the link.

## Enabling it in Mail

1. Build and run the Mac Catalyst app once so macOS registers its extensions.
   `pluginkit -m -v -i com.milestonemade.guesswho.mail` shows the registered
   copy and its path.
2. In Mail, open **Settings → Extensions** and turn on **GuessWho** (or
   **GuessWho Debug**). If Mail lists the extension's capabilities
   separately, enable both compose and message actions.

## Human runtime checks

Automated tests cover the shared formats, the wake URLs, display-name reading, the new-contact name split, cache projection, address matching, cache publication rules, preservation after a favorite-group read failure, and release of failed mail writes for retry. After enabling the extension, verify the OS-hosted MailKit behavior end to end:

- Flagging is switched off (`flagsHighlightedSenders`), so no message is flagged; skip this check and the next until it is turned back on. When on: mail from a favorite contact, a favorite group member, a favorite organization member, or a member of a favorite department arrives flagged (blue for a contact, green for a group, orange for an organization or department). Clearing the flag in Mail's Flag menu should work and is unverified. After changing a favorite group in Contacts.app, activate GuessWho before checking the new Mail highlight because this app excludes group-only changes from its Contacts history request.
- Mail from a known, non-favorite sender arrives unflagged and produces one journal entry; mail from an unknown sender produces none.
- The matching contact page shows the message under **Recent Email**, advances Last Interaction, and offers **Open in Mail** only for a safe Message-ID link.
- On the first incoming message for a known contact that has no GuessWho identity yet, the app transparently adds its private identity URL to the Contacts card before storing activity.
- `~/Library/Group Containers/<TeamID>.com.milestonemade.guesswho/Mail/incoming-messages.jsonl` holds only the metadata fields above.
- A compose window shows the toolbar button; its popover opens sized to its rows (nothing clipped, even when one address matches two contacts), stays filled, and reopening it after adding or removing recipients shows the new list. No new `GuessWhoMailExtension-*.ips` appears in `~/Library/Logs/DiagnosticReports/`.
- Clicking a known recipient slides in a detail page; **Back** returns to the list; **GuessWho** brings GuessWho forward with that contact selected. The popover is neither clipped nor left at the list's size on the detail page: a contact with little to show gets a short page with no empty space below it, and one with many emails or phone numbers stops at the list's maximum height and scrolls. Clicking **Back** and then immediately opening the same contact, or another one, still sizes the page to its content (up to the maximum height). A person with two addresses in the window appears once.
- A recipient who isn't a contact shows the name Mail gave and the address (or the address and **No contact details** when Mail gives no name), with an **Add Contact** button and no chevron; the row stays the normal height. Note whether Mail gives a display name at all, and update *Display names from Mail* with the answer.
- Clicking **Add Contact** brings GuessWho forward with the new-contact editor filled in with that name (split into its parts) and address. **Save** closes the editor and shows the new contact selected in People with its detail open; **Cancel** adds nothing. After the app republishes the cache, reopening the popover shows that recipient as a known contact.
- Clicking **Add Contact** for an address that already belongs to a contact (for example, clicking it again after saving, before the cache republishes) opens that contact instead of the editor.
- While the popover says "Contact details aren't available right now.", no row has an **Add Contact** button.
- Opening a generated message link may or may not select the message — both are acceptable.
- The Mail extension log shows no unexpected errors and never includes addresses or subjects.
