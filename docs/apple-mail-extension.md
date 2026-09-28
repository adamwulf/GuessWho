# Apple Mail extension & the Mail handoff files

This document is the source of truth for the **GuessWho Mail extension** — a
MailKit app extension for Apple Mail on the Mac — and for the two files it
shares with the app through the App Group container: the **contact cache**
the app publishes and the **incoming-message journal** the extension appends
and the app drains. Read it before touching the extension target, the files'
formats, or the code that writes or drains them.

## What it does

- **Highlights mail from favorite people.** For each newly received message, the extension looks the sender up in the contact cache. If any matching contact is a favorite, belongs to a favorite group, works at a favorite organization, or belongs to a favorite department, Mail shows the message with a blue background.
- **Records mail from known people.** For every message whose sender is in the cache, the extension appends one metadata-only entry to the journal. The app records it under **Recent Email** on every matching contact and advances Last Interaction.
- **Shows who you are writing to.** In a compose window, a toolbar button (tooltip **Recipient details**) opens a popover listing each recipient with a photo or initials, name, title, and organization. A recipient the cache does not know gets a plain **No contact details** row.

## The pieces

| Piece | Where | Role |
| ----- | ----- | ---- |
| Extension target | `App/GuessWhoMailExtension/` | Native macOS app extension (`com.apple.email.extension`). Principal class `MailExtension` vends process-wide handlers. |
| Message actions | `MessageActionHandler.swift` | `MEMessageActionHandler`: highlight + journal on each received message. |
| Compose popover | `ComposeSessionHandler.swift`, `RecipientsModel.swift`, `RecipientsView.swift`, `RecipientsViewController.swift` | `MEComposeSessionHandler` + a SwiftUI list hosted in an `MEExtensionViewController`. |
| Shared format | `App/GuessWhoMailShared/` | Foundation-only code compiled into both the extension and the app: address normalization, cache and journal formats and stores, Message-ID handling, and App Group lookup. |
| App bridge | `App/GuessWho/Support/MailBridgeController.swift` | Publishes the contact cache, drains the journal, and records contact mail activity. |
| Shared tests | `App/GuessWhoTests/MailHandoffTests.swift` | Cache, journal, bounds, concurrency, and forward compatibility. |
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
`jobTitle`, and `thumbnail` data, and a set of `highlightReasons`. Build one
with `add(_:forAddresses:)`, which normalizes every key; publish it with
`MailContactCacheStore.write(_:)`.

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
colors nothing, and the compose popover shows addresses only.

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

`MailBridgeController` is owned by `GuessWhoAppDelegate` on Mac Catalyst, so one instance serves every window. At launch it waits for the contacts repository to finish its initial load, loads the group identity cache, then publishes and drains. Contact-data reloads, group-membership changes, favorite changes, and app activation schedule a debounced publication; presentation-only reloads do not. Darwin journal notifications, repository recovery, and activation trigger a single-flight drain. A failed group load is retried on a later reload or activation instead of publishing incomplete group highlights.

The published snapshot includes every email-bearing contact so Mail can recognize compose recipients and journal known senders. Highlight reasons are projected from favorite contacts, favorite organization members, favorite department members, and favorite group members. Favorites and App Group file reads run off the main actor. Group reads are revision-checked and error-aware, and the final publish gate checks contact, membership, hierarchy, load state, and reload outcome again after every suspension. A failed favorites, groups, contacts, or stale read preserves the previous cache. Newer formats, including a breaking format whose address index this build cannot decode, are never downgraded. Equivalent current snapshots are not rewritten. Snapshot sorting is computed once per contact on a utility task. Thumbnails are capped at 256 KiB each and 8 MiB total after charging the bytes once per normalized address; transient photo read failures are retried rather than cached as no photo.

The drainer claims up to ten batches of 50 entries per pass and renews both active and deferred ownership while processing. It builds the contact-address index only after finding work, uses the same `MailAddressNormalizer` as the extension cache, and records one message against every matching contact. Writes for each contact are awaited sequentially because the first incoming activity can transparently mint the private GuessWho identity URL on its Contacts card; `MailActivity` then de-duplicates redelivery by Message-ID and advances Last Interaction only forward. Stored entries are acknowledged. An unmatched sender is acknowledged only when the current contact revision has been successfully published, proving the extension cache and repository agree that the address is gone; otherwise it is released for retry. Failed entries stay claimed while later batches drain, then are released together and retried after a delay, so one poison entry cannot pin the backlog. Claim, renewal, and release failures also schedule retries; a later pass first retries any release that previously failed. Loading or failed repository state never acknowledges an entry. Shutdown best-effort releases live claims, and fencing prevents this process from settling ownership another app copy acquired.

## Privacy

- The extension reads the From address, Subject, received date, and
  `Message-ID` header of received messages (`MEMessage.state == .received`).
  It asks Mail to fetch `Message-ID` (`requiredHeaders`) and never asks for
  the body: it never returns `invokeAgainWithBody` and never reads `rawData`.
- It journals only messages from senders in the contact cache, and only the
  fields above. Unknown senders leave no trace.
- It never annotates compose recipients; the popover only displays what the
  cache holds.
- Its log lines carry fixed messages and, for failures, only the error's
  type, `NSError` domain, and code (`LoggedError.fingerprint`) — never an
  error description, file path, coding path, address, or subject.
- Any cache or journal failure leaves the message exactly as Mail delivered
  it.

## The `message://` link is best effort

Apple has never documented Mail’s `message:` URL scheme. Mail has long answered `message://%3C<id>%3E`, but it may change or stop working in any release, and it only finds messages Mail still has locally. `MailMessageID.mailDeepLink(for:)` builds a link only from a syntactically safe Message-ID — exactly one `@`, both sides RFC 5322 dot-atom text in ASCII — and percent-encodes everything but unreserved characters and `@`. The app rebuilds the link from the canonical Message-ID both when recording and when opening a Recent Email row; it never trusts a persisted URL or a URL supplied by another process. Journaling and activity storage never depend on the link.

## Enabling it in Mail

1. Build and run the Mac Catalyst app once so macOS registers its extensions.
   `pluginkit -m -v -i com.milestonemade.guesswho.mail` shows the registered
   copy and its path.
2. In Mail, open **Settings → Extensions** and turn on **GuessWho** (or
   **GuessWho Debug**). If Mail lists the extension's capabilities
   separately, enable both compose and message actions.

## Human runtime checks

Automated tests cover the shared formats, cache projection, address matching, and cache publication rules. After enabling the extension, verify the OS-hosted MailKit behavior end to end:

- Mail from a favorite contact, a favorite group member, a favorite organization member, or a member of a favorite department arrives with a blue background.
- Mail from a known, non-favorite sender arrives uncolored and produces one journal entry; mail from an unknown sender produces none.
- The matching contact page shows the message under **Recent Email**, advances Last Interaction, and offers **Open in Mail** only for a safe Message-ID link.
- On the first incoming message for a known contact that has no GuessWho identity yet, the app transparently adds its private identity URL to the Contacts card before storing activity.
- `~/Library/Group Containers/<TeamID>.com.milestonemade.guesswho/Mail/incoming-messages.jsonl` holds only the metadata fields above.
- A compose window shows the toolbar button; its popover lists the recipients and updates as recipients are added or removed.
- Opening a generated message link may or may not select the message — both are acceptable.
- The Mail extension log shows no unexpected errors and never includes addresses or subjects.
