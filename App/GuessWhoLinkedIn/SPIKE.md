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

Status: **target added, builds clean, extension embeds, entitlement split
verified.** Runtime handoff is NOT yet verified end-to-end (needs Safari +
a real tab + manual interaction — see "Runtime validation" below).

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

## Runtime validation — what still needs a human

The build/embed/entitlement wiring is verified by `xcodebuild` + reading the
signed `.xcent` and `Info.plist` blobs. The actual handoff round-trip is NOT
verified and CANNOT be from a headless build. To validate at runtime:

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

- **Extension icons are missing.** `Resources/manifest.json` references
  `images/icon-48.png` and `images/icon-128.png`, but no `Resources/images/`
  folder exists. The build does not fail (manifest icon paths are a Safari
  runtime concern), but Safari will warn / show a placeholder until the two
  PNGs are added. Drop them at `App/GuessWhoLinkedIn/Resources/images/` — the
  synchronized group will pick them up automatically; no `.pbxproj` change.
- **App Group provisioning.** Automatic signing registered
  `group.com.milestonemade.guesswho` on both targets during the local build.
  For a clean machine / CI, ensure the App Group exists on the Apple Developer
  portal and is enabled on both App IDs
  (`com.milestonemade.guesswho` and `com.milestonemade.guesswho.safari`).
- **Catalyst wake trigger** (the one true open question) still needs the
  runtime experiment in "Wake mechanism" #1 to confirm the popup can open the
  custom scheme on Catalyst; if it can't, fall back to #2 (observe + manual
  switch).
