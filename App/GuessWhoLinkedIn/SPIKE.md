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
