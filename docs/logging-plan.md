# Logging plan: logfmt file logging shared by app + Safari extension

## Goal

Use [`adamwulf/Logfmt`](https://github.com/adamwulf/Logfmt) together with Apple's
swift-log (`apple/swift-log`) to auto-log to files with clean, consistent
**logfmt** output. Both the main app **and** the Safari Web Extension write log
files into **one shared place** (the App Group container), each process to its
**own** file (no shared-file locking). Files **rotate at 10 MB** and are
**pruned after 1 week**. In **debug mode**, a navbar **Export Logs** button zips
the log files and presents a **save dialog on macOS** / **share sheet on iOS**.

## Decisions (confirmed with the user)

1. **Pull in `apple/swift-log`** for the `Logger` / `LogHandler` API. Logfmt
   today only exposes `String.logfmt(_:)` (its swift-log integration is still
   "in progress"), so we write our own `LogHandler` that formats via Logfmt.
2. **Logfmt: track `main`, pinned to the latest commit**
   `a6d6eb29177f65f3e252610a2176d318026d634c`.
   **swift-log:** pin to release **`1.14.0`** (`.upToNextMinor(from: "1.14.0")`).
3. **Export Logs lives in the navbar, shown only in debug mode.** Simplest
   placement; no in-app Settings screen exists today (the debug toggle is a
   static `Settings.bundle`, which cannot host a button).

## Key facts discovered (constraints this plan respects)

- **Shared location = App Group, not iCloud.** The Safari extension's
  entitlement holds *only* the App Group (`group.com.milestonemade.guesswho` on
  iOS, `T68Z94627S.com.milestonemade.guesswho` on Mac Catalyst — resolved at
  runtime from the `GuessWhoAppGroup` Info.plist key, fed by `GUESSWHO_APP_GROUP`
  in the xcconfig). It has **no** iCloud entitlement. The App Group is the only
  location both processes can reach. This is deliberately **separate from the
  iCloud ubiquity (sync) container** — logs must not sync to iCloud or pollute
  synced sidecar data. (See repo note: "Sidecar root is iCloud, not App Group".)
- **Per-process files, one dir.** Per the user: separate files are fine, they
  just want them in one place. So: `<AppGroup>/Logs/app.log` and
  `<AppGroup>/Logs/extension.log` (+ their rotated siblings). No cross-process
  locking on a single file.
- **Existing logging is ad-hoc** — a mix of `os.log` `Logger` and `NSLog`:
  - `App/GuessWho/GuessWhoSceneDelegate.swift` — `Logger(subsystem:category:)`
    for the LinkedIn handoff.
  - `App/GuessWhoLinkedIn/SafariWebExtensionHandler.swift` —
    `Logger(subsystem: "com.milestonemade.guesswho.safari", category: "handoff")`.
  - `App/GuessWho/Support/SyncService.swift` — `NSLog("[GuessWho] ...")`.
  - `Sources/GuessWhoSync/ContactChangeWatcher.swift` — `NSLog("[GuessWho] ...")`.
  These continue to work (console) and additionally land in the log files once
  routed through swift-log. Migration of call sites is incremental.
- **Package wiring:** the app references the local package via
  `XCLocalSwiftPackageReference ".."` and links the `GuessWhoSync` product
  (`App/GuessWho.xcodeproj/project.pbxproj`). The extension target
  (`GuessWhoLinkedIn`) currently links **no** package product.
- **Debug toggle** is `AppSettings.Key.debugModeEnabled`
  (`com.milestonemade.guesswho.settings.debugModeEnabled`), read via
  `@AppStorage` and registered as a default in `GuessWhoAppDelegate.init()`.
  Already used to gate the contact-row reconcile checkmark and the contact
  detail Debug section.
- **App bootstrap:** `GuessWhoAppDelegate.init()` runs first and already
  registers the debug-mode default — the right spot to bootstrap logging.
- **Extension entry:** `SafariWebExtensionHandler.beginRequest(...)`.
- **Navbar pattern:** `EventsListViewController.configureAddButton()` adds a
  `UIBarButtonItem` to `navigationItem.rightBarButtonItem` via a
  `primaryAction` `UIAction` — the pattern to mirror for Export Logs.

## CLAUDE.md / product-principle compliance

- **No user-facing internal vocabulary.** The Export Logs button and any
  surrounding copy are **debug-mode-only** surfaces — the explicit carve-out in
  CLAUDE.md (like the contact-row reconcile checkmark and the Debug section).
  Even so, keep copy plain: button label "Export Logs". Do **not** use
  "sidecar", "reconcile", "EventKit", "GuessWho" (as a noun for our records) in
  the button or its share-sheet filename. The zip filename should be neutral,
  e.g. `GuessWho-Logs-YYYYMMDD-HHmmss.zip` (the app name as a brand is fine; the
  forbidden term is "GuessWho" used to *name our private record type*).
- **No sidecar seam exposed.** Logging is orthogonal to the sidecar; nothing
  here adds link/unlink/picker affordances.

## Architecture

### New SwiftPM target: `GuessWhoLogging`

Add to the existing local `Package.swift` (same one the app already references).

- **Products:** add `.library(name: "GuessWhoLogging", targets: ["GuessWhoLogging"])`.
- **Dependencies (package level):**
  - `.package(url: "https://github.com/apple/swift-log.git", .upToNextMinor(from: "1.14.0"))`
  - `.package(url: "https://github.com/adamwulf/Logfmt.git", revision: "a6d6eb29177f65f3e252610a2176d318026d634c")`
- **Target:** `.target(name: "GuessWhoLogging", dependencies: [.product(name: "Logging", package: "swift-log"), .product(name: "Logfmt", package: "Logfmt")])`
  (confirm Logfmt's product name during implementation; adjust the `.product`
  name to match its `Package.swift`).
- **Platforms:** inherited from the package (`iOS .v17`, `macOS .v14`).
- Keep it **lean** — the extension links it and extensions have tight memory
  limits. No heavy deps beyond swift-log + Logfmt.

> Re-resolve packages after editing `Package.swift` (do **not** hand-edit
> `*.resolved`). Per repo rule: update the manifest, then re-resolve.

#### Files in `Sources/GuessWhoLogging/`

1. **`LogDestination.swift`** — resolves the shared `Logs/` directory:
   - `containerURL(forSecurityApplicationGroupIdentifier:)` for the resolved App
     Group id (caller passes the id; the package stays id-agnostic).
   - Creates `<container>/Logs/` if missing.
   - **Fallback:** if the App Group container is unavailable (e.g. entitlement
     not granted at runtime), fall back to the process's Caches directory so
     logging never crashes — log a single breadcrumb about the fallback.

2. **`LogFileWriter.swift`** — serial, thread-safe append writer (an `actor`, or
   a class guarded by a private serial `DispatchQueue`; pick the simpler that
   keeps writes ordered and off the caller's thread):
   - Owns one base file (e.g. `app.log`) given a `processName`.
   - **Append** each formatted line + `\n` using a held `FileHandle`
     (open once, `seekToEnd`, write; reopen after rotation).
   - **Size rotation at 10 MB:** before/after a write, if the active file ≥
     `10 * 1024 * 1024` bytes, roll: `app.log` → `app-1.log`, shifting
     `app-(n)` → `app-(n+1)` up to a cap (e.g. keep 5 rotated files), deleting
     the oldest. Then truncate/recreate `app.log`.
   - **Age prune at 1 week:** on init and periodically (e.g. every N writes or
     on rotation), delete any file in `Logs/` whose modification date is older
     than 7 days. Prune is per-directory so it also cleans the *other* process's
     stale files harmlessly (modification-date based, no content parsing).
   - All file ops wrapped so an I/O error degrades to console logging, never a
     crash.

3. **`LogfmtLogHandler.swift`** — conforms to swift-log `LogHandler`:
   - Stores `metadata`, `logLevel`, a `label`, and a reference to the
     `LogFileWriter`.
   - On `log(level:message:metadata:source:file:function:line:)`, build a clean
     **logfmt** line. Proposed shape (stable key order, space-separated
     `key=value`):
     ```
     ts=2026-06-27T12:34:56.789Z level=info label=app.linkedin-handoff msg="..." <flattened-metadata-via-Logfmt>
     ```
     - Timestamp: ISO-8601 with milliseconds, UTC (`ISO8601DateFormatter` with
       `.withFractionalSeconds`), or a cached formatter for perf.
     - `msg` value: quote + escape per logfmt (Logfmt's formatter handles
       quoting; pass the message string through `String.logfmt(...)` for the
       value, or hand-quote consistently — implementer to confirm Logfmt's
       exact escaping API and use it so quoting is *consistent*).
     - Merge per-log metadata over handler metadata; flatten nested values with
       dot-notation via `String.logfmt(...)` (its documented behavior).
   - Implements the required `subscript(metadataKey:)` and `metadata`/`logLevel`
     properties.

4. **`GuessWhoLog.swift`** — public bootstrap + accessors:
   - `static func bootstrap(processName: String, appGroupID: String, consoleEcho: Bool = true)`:
     idempotent (guard against double-bootstrap — swift-log's
     `LoggingSystem.bootstrap` may only be called once per process; use a
     `dispatch_once`-style flag). Builds a `MultiplexLogHandler` of
     `[LogfmtLogHandler(file), <console handler>]` when `consoleEcho`, else just
     the file handler. Console handler: `StreamLogHandler.standardError` (from
     swift-log) so existing Console workflows keep working. (os.log is *also*
     still emitted by any not-yet-migrated `Logger`/`NSLog` sites.)
   - Convenience: `static func logger(_ label: String) -> Logging.Logger`
     returning a labeled swift-log `Logger`.
   - Expose the resolved `Logs/` dir URL for the exporter:
     `static func logsDirectoryURL(appGroupID:) -> URL?`.

5. **`LogExporter.swift`** — zips the shared `Logs/` directory:
   - Foundation-only zip via `NSFileCoordinator.coordinate(readingItemAt:
     options: .forUploading, ...)`: the `.forUploading` reading intent produces
     a **zip** of the directory at a temporary URL. Copy that temp zip to a
     stable temp file named `GuessWho-Logs-<timestamp>.zip` and return its URL.
     (Confirm the exact option constant name during implementation;
     `.forUploading` is the documented directory→zip path that works on both
     Catalyst and iOS without a 3rd-party archiver.)
   - Returns `URL` (the zip) or throws. Caller owns presenting it.
   - Zips **everything** in `Logs/` (both `app*.log` and `extension*.log`), so a
     single export captures both processes — matching "one place".

### App wiring (`App/GuessWho/`)

- **Link `GuessWhoLogging`** into the `GuessWho` app target (add the product
  dependency in `project.pbxproj`, mirroring the existing `GuessWhoSync`
  `XCSwiftPackageProductDependency` + Frameworks build file).
- **Bootstrap** in `GuessWhoAppDelegate.init()` (first thing, before the
  existing `UserDefaults.register`): resolve the App Group id the same way the
  SceneDelegate does (`GuessWhoAppGroup` Info.plist key, with the
  `group.com.milestonemade.guesswho` fallback) and call
  `GuessWhoLog.bootstrap(processName: "app", appGroupID: id)`.
  - **Refactor** the App-Group-id resolution into one shared helper so the
    AppDelegate, SceneDelegate, and (extension copy) don't each re-derive it.
    Smallest-footprint option: a tiny `AppGroup.id` static in the app target,
    and the extension keeps its own copy (different target, can't share app
    code without moving it into the package). Acceptable to leave existing
    `handoffAppGroupID` / `appGroupID` as-is and just add the bootstrap call,
    to keep the diff focused — implementer's judgment.
- **Migrate existing app log sites** to swift-log `Logger` from
  `GuessWhoLog.logger(...)`:
  - `GuessWhoSceneDelegate` handoff `Logger` → `GuessWhoLog.logger("app.linkedin-handoff")`.
  - `SyncService` `NSLog("[GuessWho] ...")` → `logger.notice("...")` /
    `logger.error(...)`.
  - Keep messages' content identical; only the transport changes.

### Sync package wiring (`Sources/GuessWhoSync/`)

- `ContactChangeWatcher.swift` uses `NSLog`. **Option A (preferred):** route it
  through swift-log by having `GuessWhoSync` depend on `Logging` (swift-log) and
  use a package-local `Logger`. The app bootstraps the backend, so the
  package's `Logger` automatically writes to the file too. This means adding
  `Logging` as a dependency of the `GuessWhoSync` target.
  **Option B (smaller):** leave `ContactChangeWatcher`'s `NSLog` alone for now
  (it still reaches Console; just not the file). Decide during review — Option A
  is the "clean and consistent" goal; Option B is lower-risk/smaller diff.
  Recommend **A** but call it out explicitly so the reviewer can weigh scope.

### Extension wiring (`App/GuessWhoLinkedIn/`)

- **Link `GuessWhoLogging`** into the `GuessWhoLinkedIn` extension target (new
  product dependency + Frameworks entry in `project.pbxproj`). Verify it does
  not pull in anything that breaks the appex (lean target — should be fine).
- **Bootstrap** at the top of `SafariWebExtensionHandler.beginRequest(...)`
  (idempotent, so calling on every request is safe), with
  `processName: "extension"` and the extension's already-resolved
  `Self.appGroupID`.
- **Migrate** the extension's `os.log` `Logger` calls to
  `GuessWhoLog.logger("extension.handoff")` so its breadcrumbs land in
  `extension.log`. (Console still receives them via the console echo.)

### Export UI (debug mode only)

- Add an **Export Logs** `UIBarButtonItem` (system image
  `square.and.arrow.up`) to the list controller(s)' `navigationItem`. Mirror
  `EventsListViewController.configureAddButton()`. Show it **only when**
  `UserDefaults.standard.bool(forKey: AppSettings.Key.debugModeEnabled)` is true
  — and update visibility if the toggle changes while the app is open (observe
  `UserDefaults` / `.didChangeNotification`, or re-evaluate on
  `viewWillAppear`). Keep it lightweight; simplest is re-evaluate on
  `viewWillAppear` + a `UserDefaults` observer.
  - Placement: the events list navbar already hosts the `+` button; add Export
    as a second right-bar item (or a left-bar item) there. If a single,
    always-present host is cleaner, the implementer may choose the most natural
    list controller — but it must be reachable in the normal debug flow.
- **Action:** call `LogExporter` to produce the zip, then present:
  - **iOS (non-Catalyst):** `UIActivityViewController` with the zip URL,
    `popoverPresentationController.barButtonItem = sender` (iPad/Catalyst
    popover anchor) to avoid the iPad crash.
  - **macOS Catalyst:** a **save dialog**. Use
    `UIDocumentPickerViewController(forExporting: [zipURL])` — on Catalyst this
    surfaces the macOS save/export panel; it's the cleanest cross-Catalyst path
    and avoids AppKit bridging. (Alternative: AppKit `NSSavePanel` via a Catalyst
    plugin — heavier; prefer the document picker unless it misbehaves.)
  - Run zip creation off the main thread; present on main. Surface failures with
    a simple debug-only alert ("Couldn't export logs: <error>") — plain copy.

## Testing

- **Swift package (`swift test`)** — add `Tests/GuessWhoLoggingTests` (and a
  product/target if needed) or fold into existing test target:
  - **Logfmt formatting:** a known `(level, message, metadata)` produces the
    expected logfmt line (stable key order, correct quoting/escaping, dotted
    nesting).
  - **Rotation:** writing > 10 MB rolls `app.log` → `app-1.log`; rotated count
    capped; oldest deleted.
  - **Prune:** a file with mtime > 7 days old is deleted on prune; a fresh file
    survives. (Set mtime via `FileManager.setAttributes`.)
  - **Writer ordering / no-crash on bad dir:** writing to an unwritable/missing
    dir degrades gracefully (no throw to caller).
  - **Exporter:** zipping a `Logs/` dir with two files yields a non-empty zip
    whose entries include both. (If unzip-in-test is awkward, at least assert a
    non-empty `.zip` is produced and is a valid zip header `PK\x03\x04`.)
  - Drive the writer against a **temp directory** (inject the base URL) so tests
    never touch the real App Group container.
- **Build verification:**
  - `swift build` && `swift test` from repo root (package).
  - App **Mac Catalyst** build (xcodebuild, local DerivedData).
  - App **iPhone simulator** build (xcodebuild).
  - Confirm the **extension** target still builds and links `GuessWhoLogging`.
- **Manual smoke (note in PR, not automated):** run app in debug mode → tap
  Export Logs → confirm save dialog (Catalyst) / share sheet (iOS) presents a
  zip; unzip shows `app.log` (+ `extension.log` after the extension has run).

## Risks / open items for the reviewer

1. **`.forUploading` zip path** — confirm the exact `NSFileCoordinator` reading
   option constant and that it yields a real `.zip` on both Catalyst and iOS. If
   it proves flaky, fall back to a tiny vendored zip (still Foundation/
   Compression based) — but avoid adding a heavy 3rd-party archiver to a target
   the extension links.
2. **swift-log in `GuessWhoSync`** (Option A vs B above) — scope call.
3. **Bootstrap idempotency** — `LoggingSystem.bootstrap` is once-per-process;
   the extension's per-request bootstrap must guard against re-bootstrap.
4. **Logfmt product/escaping API** — verify Logfmt's exact public surface
   (`String.logfmt`) and product name; ensure value quoting is consistent for
   messages containing spaces/quotes/newlines.
5. **Export button host** — confirm the events list navbar is an acceptable home
   (vs. a dedicated debug surface). User chose "navbar, debug mode only".
6. **Catalyst save dialog** via `UIDocumentPickerViewController(forExporting:)`
   vs. `NSSavePanel` — confirm the document-picker path gives a true save panel
   on Catalyst.
7. **Extension memory** — ensure linking `GuessWhoLogging` + swift-log + Logfmt
   stays within appex limits (lean target; expected fine).
