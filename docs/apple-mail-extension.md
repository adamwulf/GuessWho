# Apple Mail extension & the Mail handoff files

This document is the source of truth for the **GuessWho Mail extension** — a
MailKit app extension for Apple Mail on the Mac — and for the two files it
shares with the app through the App Group container: the **contact cache**
the app publishes and the **incoming-message journal** the extension appends
and the app drains. Read it before touching the extension target, the files'
formats, or the code that writes or drains them.

## What it does

- **Highlights mail from favorite people.** For each newly received message,
  the extension looks the sender up in the contact cache. If any matching
  contact is a favorite, belongs to a favorite group, or works at a favorite
  organization, Mail shows the message with a blue background.
- **Records mail from known people.** For every message whose sender is in the
  cache, the extension appends one metadata-only entry to the journal. The app
  drains it into its own storage.
- **Shows who you are writing to.** In a compose window, a toolbar button
  (tooltip "Recipient details") opens a popover listing each recipient with a
  photo or initials, name, title, and organization. A recipient the cache
  doesn't know gets a plain "No contact details" row.

## The pieces

| Piece | Where | Role |
| --- | --- | --- |
| Extension target | `App/GuessWhoMailExtension/` | Native macOS app extension (`com.apple.email.extension`). Principal class `MailExtension` vends process-wide handlers. |
| Message actions | `MessageActionHandler.swift` | `MEMessageActionHandler`: highlight + journal on each received message. |
| Compose popover | `ComposeSessionHandler.swift`, `RecipientsModel.swift`, `RecipientsView.swift`, `RecipientsViewController.swift` | `MEComposeSessionHandler` + a SwiftUI list hosted in an `MEExtensionViewController`. |
| Shared format | `App/GuessWhoMailShared/` | Foundation-only code compiled into **both** the extension and the app: address normalization, the cache and journal formats and stores, Message-ID handling, the App Group lookup. |
| Tests | `App/GuessWhoTests/MailHandoffTests.swift` | The shared format, run in the app's hosted test bundle. |

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
| --- | --- | --- | --- |
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

## The incoming-message journal (`incoming-messages.jsonl`)

### Entries

`MailIncomingMessage` — metadata only, never any part of the body. Every
text field is sender-controlled, so every bound is in **UTF-8 bytes**:

| Field | Source | Bound |
| --- | --- | --- |
| `version` | this build | — |
| `sender` | normalized From address | ≤ 320 bytes (else `append` throws `invalidEntry`) |
| `subject` | Subject, trimmed; nil when empty | clipped to 1,024 bytes at the last whole character (grapheme cluster) that fits — valid UTF-8, combining marks kept with their base; nil if even the first character doesn't fit |
| `receivedAt` | Mail's received date (now, when absent) | — |
| `messageID` | canonical `<…>` Message-ID; the de-duplication key | ≤ 986 bytes (else `invalidEntry`) |
| `messageURL` | best-effort `message://` link, may be nil | dropped when over 4 KiB |

`append` re-checks all four bounds (the fields are mutable), then refuses
any entry whose **encoded line** exceeds 16 KiB (`maximumLineByteCount`,
error `entryTooLarge`) before it touches the file, so a single crafted entry
can never evict the backlog. Every entry within the field bounds — even one
built from the characters JSON escapes most expensively — encodes under the
line cap (`worstCaseEntryFitsTheLineCap`), so the cap is a backstop.

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

1. **Claim.** `claimEntries(limit:)` atomically marks up to `limit` (default
   50) of the oldest entries that no live claim holds with a fresh token and
   returns them as a `Claim`. A second claimer — for example a Debug and an
   /Applications copy of the app — gets only entries nobody holds.
2. **Work, renewing as needed.** A claim is live for `claimLease` (5 minutes)
   from its last claim or `renew(_:)`. A drain that might run longer renews.
3. **Settle, whole or by subset.** `acknowledge(_:messageIDs:)` removes
   entries that were stored (or deliberately dropped — for example, a sender
   no longer matching any contact once the app's storage has loaded);
   `release(_:messageIDs:)` returns entries for a later retry. Settling by
   Message-ID subset keeps one entry that can't be stored from pinning or
   replaying the rest of the batch.
4. **Fencing.** `renew`, `acknowledge`, and `release` touch only lines that
   still carry the claim's token. Each returns a `ClaimOutcome` that puts
   every Message-ID asked about in exactly one bucket:
   - `applied` — held by this claim; the call acted on it.
   - `lost` — in the journal but held by a **different** claim token: this
     claim's lease lapsed and another claimer took it. A claimer with
     `lostOwnership` must treat those entries as someone else's.
   - `settledOrMissing` — held by no claim: already acknowledged or released
     (by this claim or another), evicted, or never in the journal. Nothing is
     left to do, and nobody else owns it — so a whole-claim settle after
     earlier subset settles reports the caller's own work here, not as lost.

   A lapsed claim whose entries nobody retook still settles them.
5. **Crash recovery.** A claim that is never settled expires after the lease,
   and its entries become claimable again.

### Change notification

After each successful append the journal posts the Darwin notification
`<App Group id>.mail.incoming-journal` (`MailJournalChangeNotification`), so a
running app can drain promptly; `MailJournalChangeNotification.Observer`
subscribes to it. Darwin notifications carry no payload and may coalesce: an
observer treats one as "the journal may have changed" and claims whatever is
there. Draining on activation remains the fallback.

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

Apple has never documented Mail's `message:` URL scheme. Mail has long
answered `message://%3C<id>%3E`, but it may change or stop working in any
release, and it only finds messages Mail still has locally.
`MailMessageID.mailDeepLink(for:)` builds a link only from a syntactically
safe Message-ID — exactly one `@`, both sides RFC 5322 dot-atom text in
ASCII — and percent-encodes everything but unreserved characters and `@`.
Journaling never depends on the link: an entry with no link is still
recorded.

## Enabling it in Mail

1. Build and run the Mac Catalyst app once so macOS registers its extensions.
   `pluginkit -m -v -i com.milestonemade.guesswho.mail` shows the registered
   copy and its path.
2. In Mail, open **Settings → Extensions** and turn on **GuessWho** (or
   **GuessWho Debug**). If Mail lists the extension's capabilities
   separately, enable both compose and message actions.

## Human runtime checks

Automated tests cover the shared format only. After enabling the extension,
and once the app publishes the cache and drains the journal:

- Mail from a favorite contact, a favorite group's member, or a favorite
  organization's member arrives with a blue background.
- Mail from a known, non-favorite sender arrives uncolored and produces one
  journal entry; mail from an unknown sender produces none.
- `~/Library/Group Containers/<TeamID>.com.milestonemade.guesswho/Mail/incoming-messages.jsonl`
  holds only the metadata fields above.
- A compose window shows the toolbar button; its popover lists the recipients
  and updates as recipients are added or removed.
- Opening a journaled `messageURL` (`open 'message://…'`) may or may not
  select the message — both are acceptable.
- `log stream --predicate 'subsystem == "com.milestonemade.guesswho.mail"'`
  shows no unexpected errors.
