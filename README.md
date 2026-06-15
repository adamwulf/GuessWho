# GuessWho

A Swift package that stores app-specific per-contact and per-event data as
human-readable JSON sidecar files in an iCloud Drive ubiquity container,
keyed by an app-minted UUID written onto each contact's `urlAddresses`.
Per-field LWW merge (CRDT-style) keeps multi-device edits convergent
without a server. Conflict resolution rides on `NSFileVersion`.

See [PLAN.md](PLAN.md) for the full design — schema, identity rules, merge
semantics, conflict handling, and the deferred-to-v2 list.

## Repo layout

```
Package.swift              SwiftPM manifest
Sources/GuessWhoSync/      orchestrator, protocols, real adapters, FileSystemSidecarStore
Sources/GuessWhoSyncTesting/  in-memory mocks (importable by host-app tests)
Tests/GuessWhoSyncTests/   155 tests covering §9.1–§9.8
App/                       sample iOS + Mac Catalyst app (read-only + per-contact reconcile)
PLAN.md                    design doc
```

## Building the package

```sh
swift build
swift test                # 155 tests, ~0.2s
```

No external dependencies. Foundation + Contacts + EventKit only. Minimum
deployment: iOS 17, macOS 14, Mac Catalyst 17.

## Running the sample app

The sample app reads your real contacts, lets you reconcile them one at a
time, and reads/writes JSON sidecars in your iCloud Drive ubiquity
container. It is intentionally read-only outside the explicit Reconcile
and (DEBUG-only) "Write debug field" buttons.

1. Open `App/GuessWho.xcodeproj` in Xcode.
2. Sign in to your Apple Developer account; the bundle ID is
   `com.milestonemade.guesswho` and the entitlements file declares the
   iCloud container `iCloud.com.milestonemade.guesswho`. The first build
   will prompt you to register that container in the developer portal.
3. Select **My Mac (Mac Catalyst)** for the fastest iteration; the iOS
   Simulator destination works without provisioning fixups.
4. Run. Grant Contacts access when prompted.
5. Tap a contact → tap **Reconcile this contact** → confirm. The contact
   gets a `guesswho://contact/<uuid>` URL written via `CNContactStore`.
6. (Debug builds only) Tap **Write debug field** to write a sidecar field
   for that UUID. A JSON file will appear in
   `~/Library/Mobile Documents/iCloud~com~milestonemade~guesswho/Documents/contacts/<uuid>.json`.

## Sidecar storage fallback

If iCloud Drive is unavailable (signed out, container not yet provisioned,
network down at launch), the app falls back to local-only storage under
`Application Support/GuessWhoSidecars/` and shows an orange banner
explaining the situation. If even that is unwritable, the app refuses to
read or write sidecars rather than degrade silently — the banner turns
red and Reconcile + sidecar reads are disabled. The fallback location is
resolved once at launch (relaunch the app after signing in to iCloud).

## What v1 does not do

Tracked in PLAN §10: background sync (host calls `reconcile…()`
explicitly), tombstone GC, orphan-sidecar auto-GC, and `CNContact.note`
support (entitlement-gated). The app's edit UI is also out of scope —
beyond the DEBUG-only test-field button, this is a read-and-reconcile
sample.
