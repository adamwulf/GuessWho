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
     logging never crashes — emit a single breadcrumb about the fallback **to
     `os.log`** (N2), which survives the fallback so it's diagnosable. Note that
     in this state the extension's `extension.log` lands in the appex Caches and
     the app's exporter (which zips the App Group `Logs/`) won't see it —
     acceptable degradation.

2. **`LogFileWriter.swift`** — serial, thread-safe append writer. **(N3) Use a
   class guarded by a private serial `DispatchQueue`, NOT an actor:** swift-log's
   `LogHandler.log(...)` is synchronous and non-`async`, so an actor would force
   `await` hops that can't be made from inside `log`. The serial-queue class is
   the correct fit for the synchronous `LogHandler` contract. It keeps writes
   ordered and off the caller's thread:
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
     - **(B2) `String.logfmt(_:)` is a whole-object formatter, NOT a
       single-value escaper.** Its signature is
       `static func logfmt(_ object: Any) -> String` and it emits a *full*
       `key=value key2=value2` line from a dictionary/array/object (e.g.
       `String.logfmt(["asdf": "qwer thjfdg"])` → `asdf="qwer thjfdg"`). It also
       emits the *key*, so feeding it a bare string is the wrong shape. **Do
       this instead:** build the trailing pairs by handing
       `String.logfmt(...)` a single dictionary — `["msg": message,
       <metadata…>]` — and let it emit `msg="..." key=val`. The fixed leading
       fields (`ts`, `level`, `label`) are emitted by hand so their order is
       stable; everything after `msg` comes from one `String.logfmt(dict)`
       call. (Alternatively, write a tiny local `logfmtQuote(_:)` helper for the
       leading fields and use Logfmt only for the metadata bag — implementer's
       choice, but do NOT feed `String.logfmt` a bare string expecting a value.)
     - **(B3) Guarantee one record = one line.** logfmt values containing `\n`
       or `\r` would break the per-line file format the rotation/prune logic
       assumes. Logfmt's `slashEscape` escapes quotes and backslashes but has
       **no** newline handling (no newline case in its tests; `wrapInQuotes()`
       is unconditional). So **strip or escape `\r`/`\n` in the message and in
       every metadata value before formatting** — do not rely on Logfmt for it.
       (`error.localizedDescription` routinely contains newlines.) Add a test
       with an embedded newline asserting the output is a single line.
     - Merge per-log metadata over handler metadata; flatten nested values with
       dot-notation via `String.logfmt(...)` (its documented behavior).
   - Implements the required `subscript(metadataKey:)` and `metadata`/`logLevel`
     properties.

4. **`GuessWhoLog.swift`** — public bootstrap + accessors:
   - `static func bootstrap(processName: String, appGroupID: String, consoleEcho: Bool = true)`:
     idempotent. **(S4)** swift-log's `LoggingSystem.bootstrap` is genuinely
     once-per-process and **traps** on a second call; the extension calls
     `beginRequest` per request, so the guard is **mandatory** and must wrap the
     `LoggingSystem.bootstrap` call *itself* (not just the file-writer setup),
     using a lock-protected `Bool` (`NSLock` / `os_unfair_lock`) that is safe
     under concurrent `beginRequest` invocations. Builds a
     `MultiplexLogHandler` of
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
     a **zip** of the directory at a temporary URL. Confirmed available iOS 8+ /
     Mac Catalyst 13.1+ / macOS 10.10+ (both targets covered).
   - **(S1) Copy the zip INSIDE the accessor block.** Apple's docs: "The file
     coordinator unlinks the file after the block returns, rendering it
     inaccessible through the URL." So the `copyItem`/`moveItem` from the
     coordinator's temp URL to the stable temp file named
     `GuessWho-Logs-<timestamp>.zip` **must happen within the accessor closure**;
     return the stable URL *after* the copy. Copying "after the coordinate call"
     would dead-URL and is the single most likely runtime bug in the export
     path.
   - Returns `URL` (the zip) or throws. Caller owns presenting it.
   - Zips **everything** in `Logs/` (both `app*.log` and `extension*.log`), so a
     single export captures both processes — matching "one place".

### App wiring (`App/GuessWho/`)

- **Link `GuessWhoLogging`** into the `GuessWho` app target (add the product
  dependency in `project.pbxproj`, mirroring the existing `GuessWhoSync`
  `XCSwiftPackageProductDependency` + Frameworks build file).
- **Bootstrap** in `GuessWhoAppDelegate.init()`. **(S2) Make it the FIRST
  statement in `init()`** — before both `UserDefaults.register` *and*
  `SyncService()` (which is constructed right after register at
  `GuessWhoAppDelegate.swift:36`). The backend must be live before any logger
  in the construction path can fire. Resolve the App Group id the same way the
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

- `ContactChangeWatcher.swift` has **exactly one** `NSLog`
  (`ContactChangeWatcher.swift:150`) — the only log site in the whole package.
  **(S3) Recommendation: Option B — leave it as-is.** `GuessWhoSync` currently
  has **zero external dependencies** (`Package.swift`), a meaningful property to
  keep. Routing one log line through swift-log (Option A) would add `Logging` as
  a hard dependency of both `GuessWhoSync` and its test target — not worth it
  for a single line. The `NSLog` still reaches Console; it just won't land in
  the file. Revisit (→ Option A) only if/when the package needs to log more.
  - **Option A (rejected for now):** add `Logging` to `GuessWhoSync`, use a
    package-local `Logger`; the app's bootstrap makes it write to the file too.
    Documented only so the trade-off is explicit.

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
  - Placement: the events list navbar already hosts the `+` button
    (`EventsListViewController.configureAddButton()` sets the **singular**
    `navigationItem.rightBarButtonItem` at `EventsListViewController.swift:150`).
    **(S5) Switch to `navigationItem.rightBarButtonItems` (plural array)** so
    adding Export Logs does not clobber the `+` button. If a single,
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
    **(N6/S1)** assert the returned URL is **still readable after** the
    `coordinate` call returns — this catches the unlink-after-block bug.
  - **(N6/B3) Embedded-newline message** round-trips to a **single line** in the
    file (no record split).
  - **(N6/B2) Quoting:** a message containing both a space and a `"` is quoted
    and escaped consistently in the emitted `msg=` value.
  - **(N6/S4) Double-bootstrap does not trap** — calling `bootstrap(...)` twice
    (and concurrently) is safe.
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

## Plan review — incorporated

A read-only reviewer verified this plan against the tree + Apple docs. The App
Group, pbxproj wiring, bootstrap point, debug-gating, and `.forUploading` claims
all verified true. Findings folded in above:

- **B1 — dependency-graph note (resolved-file & Logfmt platforms).** Re-resolving
  pulls **swift-log into `Package.resolved` for the first time** — expected; do
  not hand-edit `.resolved`, re-resolve via the manifest. Logfmt's own
  `Package.swift` declares only `.macOS(.v10_14)` with **no iOS platform floor**
  (`swift-tools-version: 5.10`). It links fine under the app's iOS-17 floor
  (SwiftPM defaults unspecified platforms), but the single-commit pin freezes
  that shape — note it; if the appex ever complains, the fix is upstream/fork.
- **B2 — `String.logfmt` is a whole-object formatter** (see LogfmtLogHandler
  notes above): feed it a dict, not a bare string.
- **B3 — escape/strip `\r`/`\n` ourselves** (one record = one line); Logfmt has
  no newline handling.
- **S1 — copy the zip inside the `NSFileCoordinator` accessor block** (it unlinks
  the temp file after the block returns).
- **S2 — bootstrap is the first statement in `AppDelegate.init()`**, before
  `SyncService()`.
- **S3 — Option B (leave the package's single `NSLog`)**, keeping `GuessWhoSync`
  dependency-free.
- **S4 — lock-guarded once-per-process `LoggingSystem.bootstrap`**, safe under
  concurrent `beginRequest`.
- **S5 — use `rightBarButtonItems` (plural)** so the `+` button isn't clobbered.
- **N3 — serial-`DispatchQueue` class writer** (not an actor) — `log(...)` is
  synchronous.

Remaining lower-priority notes to honor during implementation:

- **N1 — stderr echo + remaining `os_log` both show in Console** for
  not-yet-migrated sites. Acceptable, not a regression.
- **N2 — Caches fallback** (App Group unavailable) means the extension's
  `extension.log` won't reach the app's export; emit the fallback breadcrumb to
  **`os.log`** (which survives the fallback) so it's diagnosable.
- **N4 — prune deleting a file another process holds open is benign on APFS**
  (unlinked-but-open). Add a one-line note in code that this is intentional.
- **N5 — log bodies are developer-facing** and exempt from the
  no-internal-vocabulary rule (they will contain `app.linkedin-handoff`,
  `[GuessWho]`, etc.). State this in code so a future reader doesn't "fix" them.
  The button label "Export Logs" and filename `GuessWho-Logs-<ts>.zip` are plain
  and compliant.
- **N7 — appex memory: low risk, confirmed.** swift-log + Logfmt are pure-Swift,
  statically linked (no Embed phase — matches how `GuessWhoSync` is wired);
  deployment targets match (iOS 17 / macOS 14).

### pbxproj wiring (confirmed feasible)

The hand-authored deterministic-ID pbxproj links `GuessWhoSync` via a quartet:
`PBXBuildFile` → app Frameworks phase → `packageProductDependencies` →
`XCSwiftPackageProductDependency`. For `GuessWhoLogging`:

- Replicate that quartet for the **app** target, and a parallel set for the
  **extension** target (its Frameworks phase + `packageProductDependencies` are
  currently empty).
- Use **two distinct** `XCSwiftPackageProductDependency` objects (one per
  target) referencing the same product name — do **not** share one `productRef`
  across both Frameworks phases.
- Reuse the existing `XCLocalSwiftPackageReference ".."` (no new package
  reference — `GuessWhoLogging` lives in the same `Package.swift`).
- **No Embed phase** for either target (static linking, like `GuessWhoSync`).

> If `.forUploading` ever proves flaky in practice, the only sanctioned fallback
> is a tiny Foundation/`Compression`-based zip — **never** a heavy 3rd-party
> archiver, since the extension links this module.
