# Step-0 spike: extension → app handoff

Goal: prove the **single biggest unknown** before any feature work — that a
Safari Web Extension can hand a payload to the GuessWho **app process** (not do
the work in the extension), with the right entitlement split. No LinkedIn
parsing, no Contacts, no diff. Just the pipe.

## What "proven" means (acceptance)

1. The extension builds and loads in Safari (macOS/Catalyst first).
2. On a `linkedin.com/in/…` tab, clicking the toolbar popup → "Send to GuessWho":
   - content script returns a minimal probe (slug + title),
   - background relays it to the native handler via `sendNativeMessage`,
   - the native handler (EXTENSION process) writes `pending-handoff.json` into
     the **App Group** container `group.com.milestonemade.guesswho`,
   - the **GuessWho app** receives the wake, reads + clears the file, and shows
     the payload (a temporary alert/log is fine for the spike).
3. Confirm the entitlement split:
   - app target: iCloud + Contacts + **App Group** (already has iCloud/Contacts).
   - extension target: **App Group only** — NOT iCloud, NOT Contacts.

## The open question this spike answers

`wakeApp()` in `SafariWebExtensionHandler.swift` is a STUB marking the seam.
The Catalyst/iOS mechanism to bring the app forward is the thing to validate.
Candidate mechanisms, in rough preference order:

1. **App polls / observes the App Group** and the user switches to the app
   themselves (simplest; no wake needed — verify the file round-trips).
2. **Custom URL scheme** `guesswho-linkedin://handoff` — app registers
   `CFBundleURLTypes`; something opens it. (Distinct from the existing
   `guesswho://contact/<uuid>` identity scheme — do not collide.)
3. **`SFSafariApplication`** APIs (macOS-leaning).

Pick whichever actually fires on Catalyst; record the result here.

## App-side receiver (net-new, small)

- `Info.plist`: register `CFBundleURLTypes` for `guesswho-linkedin` IF we go the
  URL-scheme route.
- `GuessWhoSceneDelegate`: add `scene(_:openURLContexts:)` (none today) to
  receive the wake, read+clear `pending-handoff.json` from the App Group, and
  surface the payload. Keep it a thin spike receiver — no Contacts work.

## Source already authored (this commit)

`App/GuessWhoLinkedIn/Resources/` — `manifest.json` (MV3, non-persistent
service worker; `linkedin.com` + `licdn.com` host perms), `background.js`,
`content.js`, `popup.html`, `popup.js`. `SafariWebExtensionHandler.swift` —
native handler that parks to App Group + stubs the wake.

## Build

- New Safari Web Extension target `GuessWhoLinkedIn`, bundle id
  `com.milestonemade.guesswho.safari`, team `T68Z94627S`, embedded in the app.
- `App/Config/` xcconfig-driven settings; per-SDK entitlements pattern exists.
- Expect `.pbxproj` work; if GUI steps are unavoidable, document them here and
  hand them to the user rather than leaving the project unbuildable.
- Build per CLAUDE.md (Catalyst destination, local DerivedData).

## Explicitly NOT in this spike

LinkedIn DOM parsing, photo bytes, Contact-info modal, contact matching,
before/after diff, `.blob`/previous-photo, iOS target. All later steps.

## Wiring result (step-0, this commit)

Status: **PROVEN END-TO-END on Mac Catalyst (2026-06-26).** Target added,
builds clean, extension embeds, entitlement split verified, AND the full
runtime round-trip was confirmed by hand — see "Runtime validation result"
below.

What was wired into `App/GuessWho.xcodeproj` (objectVersion 77, file-system
synchronized groups — matching the existing app target):

- New `com.apple.product-type.app-extension` target **GuessWhoLinkedIn**,
  bundle id `com.milestonemade.guesswho.safari`, team `T68Z94627S`, automatic
  signing. Source is the committed `App/GuessWhoLinkedIn/` folder (a
  synchronized root group), NOT a regenerated template.
- Explicit `App/GuessWhoLinkedIn/Info.plist` carrying the
  `NSExtension` dict (`NSExtensionPointIdentifier =
  com.apple.Safari.web-extension`, `NSExtensionPrincipalClass =
  $(PRODUCT_MODULE_NAME).SafariWebExtensionHandler`). The synchronized-group
  exception set keeps `Info.plist`, `GuessWhoLinkedIn.entitlements`, and
  `SPIKE.md` out of the bundled resources.
- Version single-sourced: the extension's build configs use
  `Config/SharedVersion.xcconfig` as their base config, so its
  `CFBundleShortVersionString` tracks the app's (`0.1`) — the app-extension
  version-mismatch warning is gone.
- App target gains an **Embed Foundation Extensions** copy-files phase
  (`dstSubfolderSpec = 13`) + a target dependency on the extension, so the
  `GuessWho` scheme builds and embeds the appex automatically. Verified at
  `GuessWho.app/Contents/PlugIns/GuessWhoLinkedIn.appex` (Catalyst) and
  `GuessWho.app/PlugIns/GuessWhoLinkedIn.appex` (iOS Simulator).

Entitlement split (read back from the signed `.xcent` blobs):

- **App** (`com.milestonemade.guesswho`): App Group + iCloud (CloudDocuments +
  ubiquity container) + Contacts + Calendars + app-sandbox. App Group added to
  BOTH `GuessWho.entitlements` (iOS) and `GuessWho-MacCatalyst.entitlements`.
- **Extension** (`com.milestonemade.guesswho.safari`): App Group +
  app-sandbox **only** — NO iCloud, NO Contacts, NO Calendars. New file
  `App/GuessWhoLinkedIn/GuessWhoLinkedIn.entitlements`.

Builds verified (per CLAUDE.md, local `.build/DerivedData`):

- Mac Catalyst (`platform=macOS,variant=Mac Catalyst`): **BUILD SUCCEEDED**.
- iOS Simulator (`generic/platform=iOS Simulator`): **BUILD SUCCEEDED**
  (sanity check — the shared scene-delegate receiver compiles on both paths;
  iOS feature work is still out of scope).

## Wake mechanism — chosen + the Catalyst finding

**Chosen receiver mechanism: custom URL scheme `guesswho-linkedin://handoff`**
(candidate #2). The app now:

- registers `CFBundleURLTypes` for the `guesswho-linkedin` scheme in
  `App/GuessWho/Info.plist` (it had none). Only `guesswho-linkedin` is
  registered — the existing `guesswho://contact/<uuid>` identity scheme is
  untouched, so there is no collision.
- handles the wake in `GuessWhoSceneDelegate`: a new
  `scene(_:openURLContexts:)` (running-app path) plus draining
  `connectionOptions.urlContexts` in `willConnectTo` (cold-launch path). Both
  funnel into `handleLinkedInHandoff`, which filters for the
  `guesswho-linkedin` scheme, reads **and clears** `pending-handoff.json` from
  the App Group container, `os_log`s the payload, and shows a throwaway
  `UIAlertController`. No Contacts / sidecar work, per spec.

**Open-question finding — who actually opens the URL on Catalyst:** a Safari Web
Extension's *native handler* runs in an NSExtension process that **cannot bring
the container app forward** — there is no `UIApplication.shared` in an extension
process, and `SFSafariApplication`'s open/messaging APIs are legacy
macOS-AppKit-only (absent from the Catalyst SDK) and point app→extension-JS
anyway, not an app-wake. (Review caught that the original `wakeApp()` stub called
the wrong API on *every* platform, not just a Catalyst no-op; it has been
**removed** and replaced with an explanatory note.)

**Resolved direction (wired this revision):** the wake is initiated from the
**web** side — the popup opens the `wakeURL` (`guesswho-linkedin://handoff`)
returned in the native ack (`popup.js`: `window.location.href = wakeURL`). The
browser web context can navigate to a registered custom scheme; the app's
`GuessWhoSceneDelegate` receives it and drains the parked payload. Still needs
runtime confirmation on Catalyst (manual Safari enable), with the App-Group
fallback below if the navigation is blocked. The viable triggers, all landing on
the same app-side receiver, are:

1. The **popup web page** navigates to `guesswho-linkedin://handoff` (e.g.
   `window.location = "guesswho-linkedin://handoff"` after the native ack).
   This runs in the browser's web context, which CAN open a registered custom
   scheme, and is the most promising Catalyst path to validate next.
2. The app **observes the App Group** file (candidate #1) and the user switches
   to it manually — no wake needed; the receiver's read+clear logic is already
   what runs on `willConnectTo` / foreground.

The app-side receiver is mechanism-agnostic: whichever of the above fires the
URL (or if the app is simply brought forward and re-reads on activation), the
read+clear+surface path is identical and already wired.

## Runtime validation RESULT (2026-06-26) — PASSED

Validated by hand on Mac Catalyst (debug build attached to Xcode), on a real
`linkedin.com/in/adamwulf/` tab. The full chain works:

- content script probe → background → `sendNativeMessage` → native handler,
- handler parked `pending-handoff.json` in the App Group,
- the **popup's web-side navigation to `guesswho-linkedin://handoff` brought the
  GuessWho app forward** — this answers the spike's one true open question:
  **the Catalyst web-side wake fires.** (No App-Group-observe fallback needed.)
- the app read + cleared the file and surfaced the payload:
  `{ "payload": { "slug": "adamwulf", "sourceUrl":
  "https://www.linkedin.com/in/adamwulf/", "title": "Adam Wulf | LinkedIn" },
  "stampedBy": "extension" }`.

Two findings worth carrying forward:

- **macOS App Group consent prompt.** macOS showed *"GuessWho would like to
  access data from other applications"* (the group-container access prompt),
  once per process touching the container (extension write + app read = up to
  two prompts on first run). This is the **macOS sandbox** behavior for App
  Groups; on a real **iOS device, own-app↔own-appex App Group access is silent**
  (no prompt). It is one-time-per-process, expected, and confirms the data
  really flows through the sandboxed shared container.
  - **Root cause + fix (verified vs. Apple docs `accessing-app-group-containers`,
    macOS 15+):** the prompt fires when a process touches a group container whose
    app-group entitlement is **not authorized/validated** at runtime — NOT
    because of the prefix per se. Two complementary fixes, both applied:
    1. **`REGISTER_APP_GROUPS = YES`** (added to app xcconfig + extension build
       configs) so automatic signing fetches a profile that authorizes the
       `group.`-prefixed id. Verify with
       `sudo launchctl procinfo \`pgrep GuessWho\`` → expect `entitlements
       validated`.
    2. **Per-SDK App Group identifier (decided 2026-06-26):**
       - iOS/iPadOS: `group.com.milestonemade.guesswho` (only form iOS supports;
         needs provisioning, handled by #1).
       - **Mac Catalyst: `$(DEVELOPMENT_TEAM).com.milestonemade.guesswho`** — the
         `<TeamID>.<name>` form is **self-authorizing by code signature**, needs
         no provisioning profile and no portal registration, and **avoids the
         prompt**. NOT supported on iOS, hence the split. Defined as
         `GUESSWHO_APP_GROUP` (with an `[sdk=macosx*]` override) in
         `GuessWho-Shared.xcconfig`.
       - The two platforms therefore use DIFFERENT container ids — fine, since
         iOS and Catalyst are separate installs that never share a container
         (cross-device data syncs via iCloud, not the App Group).
       - **Consequence for the implementation:** the identifier must be selected
         per-platform in FOUR places kept in lockstep — iOS entitlements, Catalyst
         entitlements, the EXTENSION's entitlements (needs its own `[sdk=macosx*]`
         second file, like the app), and the Swift code (`appGroupID` /
         `handoffAppGroupID` must read the value from an Info.plist key fed by
         `GUESSWHO_APP_GROUP`, not a hardcoded literal). A mismatch silently
         breaks container resolution.
  - *Alternative considered:* carry text inline in the deep link
    (`guesswho-linkedin://handoff?data=<base64>`) and skip the App Group — but
    the real v1 **photo bytes** are too big for a URL, so the App Group stays.
- The probe must be **injected on demand**: a tab open *before* the extension
  was enabled has no content script, so the popup now
  `scripting.executeScript`s `content.js` and retries (fixed in commit that
  followed the first runtime attempt).

## Runtime validation procedure (for re-running)

The build/embed/entitlement wiring is verified by `xcodebuild` + reading the
signed `.xcent` and `Info.plist` blobs. To re-validate the round-trip at
runtime:

1. Run the `GuessWho` Catalyst app once so LaunchServices registers the
   embedded appex and the `guesswho-linkedin` scheme.
2. In Safari → Settings → Extensions, enable **GuessWho LinkedIn** (developer
   "Allow unsigned extensions" / "Allow Unsigned…" may be needed for a local
   dev build).
3. Open a real `https://www.linkedin.com/in/<slug>` tab, click the toolbar
   popup → **Send to GuessWho**.
4. Confirm: popup shows the native ack; `pending-handoff.json` appears in the
   App Group container; the GuessWho app surfaces the payload alert (after the
   wake trigger from "Wake mechanism" above fires, or after switching to the
   app). Check Console for the `linkedin-handoff` os_log breadcrumbs
   (subsystem `com.milestonemade.guesswho`).

## Remaining manual steps

No Xcode-GUI-only steps were required — the target was added entirely by
`.pbxproj` surgery and the project builds from the command line. The items
below are NOT blockers for the build; they are follow-ups for runtime:

- **Extension icons** — RESOLVED: the nonexistent `images/icon-*.png` refs were
  removed from `manifest.json` (they caused Safari's "invalid path" / "failed to
  load images" errors). Real icons are a later cosmetic follow-up; drop PNGs at
  `App/GuessWhoLinkedIn/Resources/images/` + restore the manifest `icons` block.
- **Catalyst wake trigger** — RESOLVED: confirmed at runtime that the popup
  navigating to `guesswho-linkedin://handoff` brings the app forward on Catalyst.
- **App Group provisioning.** Automatic signing registered
  `group.com.milestonemade.guesswho` on both targets during the local build.
  For a clean machine / CI, ensure the App Group exists on the Apple Developer
  portal and is enabled on both App IDs
  (`com.milestonemade.guesswho` and `com.milestonemade.guesswho.safari`).
- **macOS App Group consent prompt** — open follow-up (see "Runtime validation
  RESULT"). Investigating whether the prompt can be avoided; iOS does not show
  it. See the App-Group-prefix analysis below.
