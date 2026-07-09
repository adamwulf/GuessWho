# GuessWho

A contacts-and-events app whose GuessWho-only data — notes, tags, links,
favorites, photo snapshots — lives in **sidecar** JSON files, while the
records themselves stay sourced from Contacts.app and Calendar.app. The
sidecar files sync as human-readable JSON in an iCloud Drive ubiquity
container, keyed by an app-minted UUID written onto each contact's
`urlAddresses`. Per-field LWW merge (CRDT-style) keeps multi-device edits
convergent without a server; conflict resolution rides on `NSFileVersion`.

The sidecar is an **implementation detail the user never sees** — from the
user's perspective there is one kind of contact and one kind of event. See
[CLAUDE.md](CLAUDE.md) for that product principle and [PLAN.md](PLAN.md) for
the full storage/sync design (schema, identity, merge, conflict handling).

## Repo layout

```
Package.swift                 SwiftPM manifest
Sources/GuessWhoSync/         storage + sync engine: sidecar store, EventKit/Contacts
                              adapters, ContactsRepository, model types, reconciliation
Sources/GuessWhoLogging/      GuessWhoLog — a thin facade over FellerBuncher (swift-log)
Sources/GuessWhoSyncTesting/  in-memory store fakes (importable by host-app tests)
Tests/                        XCTest + swift-testing suites for the package
App/GuessWho/                 the app: Catalyst 3-column + iPhone tab-bar UIKit shells,
                              SwiftUI detail/editor views
App/GuessWhoLinkedIn/         Safari Web Extension (LinkedIn profile capture)
App/GuessWhoAppKitBridge/     in-process AppKit .bundle for the rare AppKit-only needs
docs/                         current architecture docs (identity, LinkedIn extension, …)
```

## Building & testing

**Package** (storage + sync engine, no app shell):

```sh
swift build          # compile GuessWhoSync + GuessWhoLogging + GuessWhoSyncTesting
swift test           # run the package test suites
```

**App** — build from `App/GuessWho.xcodeproj` (scheme `GuessWho`). See
[CLAUDE.md](CLAUDE.md#building--testing) for the exact `xcodebuild`
invocations (Mac Catalyst and iPhone simulator destinations, local
DerivedData).

Deployment floor: the SwiftPM package targets iOS 17 / macOS 14; the app
target is pinned higher (currently iOS 26) in the Xcode project. **Mac
Catalyst is the macOS strategy** (not native macOS); the AppKit bridge
bundle covers the few AppKit-only affordances.

Dependencies: `GuessWhoSync` is Foundation + Contacts + EventKit plus
[swift-log](https://github.com/apple/swift-log) (the `Logger` API every
call site uses); `GuessWhoLogging` adds
[FellerBuncher](https://github.com/adamwulf/FellerBuncher), which owns the
swift-log bootstrap and file-destination fan-out.

## Running the app

1. Open `App/GuessWho.xcodeproj` in Xcode.
2. Sign in to your Apple Developer account. Bundle id is
   `com.milestonemade.guesswho` for both Debug and Release; the entitlements
   declare the iCloud container `iCloud.com.milestonemade.guesswho`. The
   first device build prompts you to register that container in the portal.
3. Select **My Mac (Mac Catalyst)** for the fastest iteration; the iOS
   Simulator destination works without provisioning fixups.
4. Run. Grant Contacts (and Calendar) access when prompted.

The app reads your real contacts and events, and reads/writes sidecar JSON
in your iCloud Drive ubiquity container. A contact adopts a
`guesswho://contact/<uuid>` identity URL **lazily** — the first time you
attach GuessWho data to it (a note, tag, link, or favorite), reconciliation
mints the URL and writes the sidecar. Reading a contact never mints
anything. Sidecar files land in
`~/Library/Mobile Documents/iCloud~com~milestonemade~guesswho/Documents/`.

## Sidecar storage fallback

If iCloud Drive is unavailable (signed out, container not yet provisioned,
network down at launch), the app falls back to local-only storage under
`Application Support/GuessWhoSidecars/` and shows an orange banner
explaining the situation. If even that is unwritable, the app refuses to
read or write sidecars rather than degrade silently — the banner turns red
and sidecar reads/writes are disabled. The fallback location is resolved
once at launch (relaunch the app after signing in to iCloud).

## What v1 does not do

Tracked in PLAN §10: background sync (the host drives reloads explicitly),
tombstone GC, orphan-sidecar auto-GC, and — on distribution builds —
`CNContact.note` read/write, which is gated on the
`com.apple.developer.contacts.notes` entitlement (see
[docs/contacts-notes-entitlement-application.md](docs/contacts-notes-entitlement-application.md)).
