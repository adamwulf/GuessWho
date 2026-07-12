# LinkedIn Safari Web Extension & the extension↔app handoff

This document is the source of truth for how the **GuessWho LinkedIn** Safari
Web Extension works, how it communicates with the GuessWho app, and the App
Group rules that differ between iOS and Mac Catalyst. Read it before touching
the extension target, the App Group identifiers, the entitlements, or the
handoff code.

> **Chrome/Brave sibling:** `App/GuessWhoChrome/` ships the same extension for
> Chromium browsers, assembled from this target's `Resources/` by its
> `build.sh` (the parser, content script, and popup are shared **verbatim** —
> editing them here changes both extensions). Its transport differs (no App
> Group, no native handler): the wake URL plus a `POST` to the app's
> loopback-only listener (`LinkedInLocalhostReceiver`), converging on the same
> `processLinkedInHandoff` pipeline. See `App/GuessWhoChrome/README.md`.

For the product rationale and the broader build plan, see
[`plans/linkedin-safari-extension.md`](../plans/linkedin-safari-extension.md).

## Why an extension (not an API)

A server-side fetch of a LinkedIn profile URL returns **HTTP 999** (anti-bot),
and the official LinkedIn API can't look up an arbitrary third party by URL. A
Safari Web Extension instead runs **inside the user's already-authenticated
Safari tab**, reading the DOM the user is already viewing. No bot fetch, no 999.
The feature is deliberately **user-initiated and user-confirmed** — it acts only
on the active tab on an explicit click, and the user reviews a before/after diff
before anything is saved.

## The three pieces

The extension is bundled inside the GuessWho app as a single
`com.apple.product-type.app-extension` target named **`GuessWhoLinkedIn`**
(bundle id `com.milestonemade.guesswho.safari`), embedded into the app via an
*Embed Foundation Extensions* copy-files phase.

| Piece | Where | Role |
| --- | --- | --- |
| Content script | `App/GuessWhoLinkedIn/Resources/content.js` + `parse-profile.js` | Runs in `linkedin.com/in/*` tabs (both files listed in the manifest's `content_scripts[].js` and injected into the same page context). `parse-profile.js` is the real parser: `extractProfile` anchors on **stable semantic signals** (page `<title>`, photo `alt`, top-card order, the "About" and "Experience" `<h2>`s) — never LinkedIn's obfuscated class names — `extractExperience` walks the Experience card's entry wrappers into structured positions (title/org/dates, current position feeds `title`/`org`), and `extractContactInfo` opens the "Contact info" overlay, parses emails/websites/profile URL, and restores the page. `content.js` orchestrates the probe: run the parser as a fallback; scroll the profile to mount every lazy-rendered section and re-parse (`forceLazySections` — unconditional on every probe, optimizing for complete data over wait time). The pass is **readiness-driven and unbounded** (no deadline): it steps the scroller in small increments, looping top→bottom repeatedly (scrolling a section back out of view can cancel its in-flight lazy load), until every *scroll-mountable* required section — identity, Experience, About (see `profileReadiness`) — is in the DOM. About renders **above** Experience, so once Experience has mounted, an absent About can't still be coming — `profileReadiness` counts About done then, so a profile with no About text finishes on its own instead of scrolling until "Save anyway". Contact info can't be scrolled in, but the "Contact info" LINK lives in the top card (in the DOM from first paint), so `extractProfile` records `hasContactInfoLink` and `profileReadiness` uses it as a definitive signal: a profile with **no** link has nothing to fetch, so that fourth section is done immediately (it reaches 4/4 without any overlay). When the link **is** present, the overlay runs once after the scroll pass, waits for the contact fields to actually load into the dialog (not just the frame), parses emails/websites/profile URL, and restores the page. The only early exit is the popup's **"Save anyway"** button, which sends a `guesswho.interrupt` (keyed on `probeId`) that the loop checks each tick and bails; the pass always restores the user's scroll position. **The window does NOT scroll on a LinkedIn profile** — `document.documentElement.scrollHeight` reads exactly one viewport; the real content lives in a nested `<main>` scroll container, so `resolveScroller()` walks up from a content anchor to the genuinely-scrollable ancestor and the pass drives *that* element's `scrollTop` (driving the window is a no-op and mounts nothing). Then fetch the full-res photo bytes in-session as a `data:` URL; and reply to the popup. Every field is best-effort/null-on-failure; if the parser is missing or throws, `content.js` falls back to `minimalProbe()` (slug + title) so the pipe still proves out. |
| Background service worker | `App/GuessWhoLinkedIn/Resources/background.js` | The **only** place that can talk to native. Relays content/popup messages to the native handler via `sendNativeMessage`. Non-persistent (MV3 `service_worker`) — required on iOS, fine on macOS. |
| Popup | `App/GuessWhoLinkedIn/Resources/popup.{html,js}` | User-facing toolbar UI. Orchestrates: probe the tab → hand off to native → open the wake URL. Sized for a phone sheet so it ports to iOS. |
| Native handler | `App/GuessWhoLinkedIn/SafariWebExtensionHandler.swift` | Runs in the **extension process**. Parks the payload in the App Group and returns the wake URL. Holds **App Group only** — no Contacts, no iCloud. |
| App receiver | `App/GuessWho/GuessWhoSceneDelegate.swift` | Runs in the **app process**. Receives the wake URL, drains the parked payload, then **matches** the profile, builds a **per-field before/after diff**, and presents a **confirm sheet** that saves the checked fields (see [Match → diff → confirm → save](#match--diff--confirm--save-app-side)). |

Rice profile support uses the same transport and confirmation pipeline. The
manifests match `profiles.rice.edu/faculty/*` and `/staff/*`;
`extractRiceProfile` reads the server-rendered profile name, first title,
department/office units, bio, email, phone, listed websites, and profile image.
Rice pages do not need the LinkedIn lazy-scroll or contact-overlay steps. The
content script still fetches the image bytes in-page and attaches the same
`photo` payload. On save, title/email/phone/websites/photo use normal Contacts
fields, the Rice profile URL is added as a website labeled `Rice`, and
department/bio upsert the named `Rice Department` and `Rice Bio` fields.

## Two processes, two channels — do not conflate them

The native handler does **not** run in the app. A Safari Web Extension's native
handler runs in its **own NSExtension process**. There are two distinct
communication channels:

1. **Extension JS ↔ native handler** (both inside the extension process):
   **Safari native messaging.** Content scripts cannot call native directly;
   they message the background worker
   (`browser.runtime.sendMessage`), which calls
   `browser.runtime.sendNativeMessage(...)`. The payload travels in
   `NSExtensionItem.userInfo` under `SFExtensionMessageKey`; the handler replies
   the same way from `beginRequest(with:)`.
   - **Safari ignores the application-identifier argument** to
     `sendNativeMessage` — it always routes to this extension's own handler.
     Don't design around addressing a specific id.
   - Payload **shape varies by Safari version**: it can arrive as the object
     directly or wrapped under a `"message"` key. `extractPayload(from:)` checks
     both.

2. **Extension process ↔ app process** (separate sandboxes, no shared memory):
   the **App Group container** (a parked file) plus a **custom URL** to wake the
   app. This is the "handoff" below.

## Why the native handler can't wake the app itself

This was the spike's key finding. A Safari Web Extension's native handler runs
in an NSExtension process that **cannot bring the container app forward**:

- there is no `UIApplication.shared` in an extension process, so no `open(_:)`;
- `SFSafariApplication`'s open/messaging APIs are legacy **macOS-AppKit only**
  (absent from the Catalyst SDK), and `dispatchMessage` is the
  app→extension-JS direction anyway — not an app-wake, on **any** platform.

So the wake is initiated from the **web side**: the popup opens a custom URL the
app registers, and the app's scene delegate handles it.

## The handoff, step by step

```
LinkedIn tab ──DOM──▶ content.js
   │  browser.runtime.sendMessage({type:"guesswho.handoff", payload})
   ▼
background.js ──browser.runtime.sendNativeMessage──▶ SafariWebExtensionHandler   (EXTENSION process)
   │                                                   │ parkPayload() writes
   │                                                   ▼ <AppGroup>/pending-handoff.json
   │  ack {received, wakeURL:"guesswho-linkedin[-debug]://handoff"}
   ▼
popup.js  ── window.location.href = wakeURL ──▶  GuessWhoSceneDelegate           (APP process)
                                                  │ scene(_:openURLContexts:) /
                                                  │ willConnectTo cold-launch drain
                                                  ▼ reads + DELETES pending-handoff.json
                                                    → match → diff → confirm sheet → save
```

Concrete contract:

- **Parked file:** `pending-handoff.json` (`handoffFilename`) in the App Group
  container. Written by `SafariWebExtensionHandler.parkPayload(_:)` with
  `{ "payload": …, "stampedBy": "extension" }`.
- **Wake URL:** `guesswho-linkedin://handoff` (Release) /
  `guesswho-linkedin-debug://handoff` (Debug). The scheme is per-configuration
  (`GUESSWHO_LINKEDIN_URL_SCHEME` in each target's per-config xcconfig) so the
  extension wakes the app built for the same configuration. Registered in
  `App/GuessWho/Info.plist` under `CFBundleURLTypes` as
  `$(GUESSWHO_LINKEDIN_URL_SCHEME)`, and read at runtime from the
  `GuessWhoLinkedInURLScheme` Info.plist key on both sides
  (`LinkedInHandoffScheme.scheme` in the app,
  `SafariWebExtensionHandler.handoffURL` in the extension) — mirroring how
  `GuessWhoAppGroup` flows.
  - **Do not collide** with the unrelated `guesswho://contact/<uuid>` identity
    URL — that is a CNContact data-storage value (a `SidecarKey` payload), not a
    launch scheme. The handoff receiver filters strictly on
    `scheme == LinkedInHandoffScheme.scheme`.
- **Receiver:** `GuessWhoSceneDelegate.handleLinkedInHandoff(urlContexts:)`,
  reached from both `scene(_:openURLContexts:)` (running app) and a
  `connectionOptions.urlContexts` drain in `willConnectTo` (cold launch). It
  **reads and immediately deletes** the file (replay-proof) and caps the read
  size (`handoffMaxBytes`, 8 MB) so it never loads an unbounded/hostile file.

The App Group is used **only** for this ephemeral handoff. It is NOT synced
storage — the synced GuessWho sidecar lives in the **iCloud ubiquity container**
(`iCloud.com.milestonemade.guesswho`), a different container entirely. The
container id is build-driven the same way the App Group is — see
[Debug vs. Release identifiers](#debug-vs-release-identifiers) below — and is
resolved at runtime via the `GuessWhoiCloudContainer` Info.plist key
(`ICloudContainer.id`, mirroring `AppGroup.id`). See
[`docs/contact-identity.md`](./contact-identity.md) and the sidecar storage
code for that side.

## App Groups: iOS vs. Mac Catalyst (the important part)

The App Group identifier is **different on each platform**, and getting this
wrong produces either a permission prompt or a silent "containers don't match"
failure. Per Apple's
[App Groups Entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.application-groups)
and
[Accessing app group containers](https://developer.apple.com/documentation/xcode/accessing-app-group-containers):

| Platform | App Group identifier (Release) | Why |
| --- | --- | --- |
| iOS / iPadOS | `group.com.milestonemade.guesswho` | The `group.`-prefixed form is the only one iOS supports. It must be **provisioned** — set `REGISTER_APP_GROUPS = YES` so automatic signing fetches a profile that authorizes it. |
| Mac Catalyst | `T68Z94627S.com.milestonemade.guesswho` (`<TeamID>.<name>`) | Self-authorizing by code signature — **no provisioning, no portal registration**, and it **avoids the macOS 15+ "GuessWho would like to access data from other applications" prompt**. This form is *not supported on iOS*, which is why the identifier must differ per platform. |

Debug and Release now use the same App Group identifiers so Xcode Debug builds
exercise the same provisioned capabilities and shared-container behavior as
production — see [Debug vs. Release identifiers](#debug-vs-release-identifiers).

Two installs on two platforms never share a container anyway (cross-device data
syncs via iCloud, not the App Group), so different identifiers are harmless.

### The macOS prompt — root cause

The "access data from other applications" prompt (macOS 15+) fires when a
process touches a group container whose app-group entitlement is **not
authorized/validated at runtime** — it is *not* about the prefix per se. Two
complementary fixes, both applied: `REGISTER_APP_GROUPS = YES` (authorizes the
`group.` form on iOS) and the self-authorizing `<TeamID>.` form on Catalyst
(which needs no provisioning). With the `<TeamID>.` form, Catalyst shows **no
prompt**. Diagnose authorization with:

```sh
sudo launchctl procinfo `pgrep GuessWho`   # expect "entitlements validated"
```

### How the identifier flows to code (keep all four in lockstep)

A mismatch between any of these silently breaks container resolution:

1. **xcconfig var** — `GUESSWHO_APP_GROUP`, a literal value with a `[sdk=macosx*]`
   override, written out in the per-configuration target xcconfig (no composing
   variable). It lives in `App/Config/GuessWho-Release.xcconfig` and
   `App/Config/GuessWho-Debug.xcconfig` for the app, and the matching
   `GuessWhoLinkedIn-*` xcconfigs for the extension:
   ```
   GUESSWHO_APP_GROUP = group.com.milestonemade.guesswho
   GUESSWHO_APP_GROUP[sdk=macosx*] = $(DEVELOPMENT_TEAM).com.milestonemade.guesswho
   ```
2. **Info.plist key** — both the app's and the extension's `Info.plist` carry
   `GuessWhoAppGroup = $(GUESSWHO_APP_GROUP)`.
3. **Swift code** — `SafariWebExtensionHandler.appGroupID` and
   `GuessWhoSceneDelegate.handoffAppGroupID` read that Info.plist key
   (`Bundle.main.object(forInfoDictionaryKey: "GuessWhoAppGroup")`), never a
   hardcoded literal. So the runtime container always matches the entitlement.
4. **Entitlements files** — per-target and per-SDK. Debug and Release both point
   at the same production entitlement files so Debug builds can exercise the
   same Apple-approved capabilities:
   - App: `GuessWho.entitlements` (iOS, `group.` form) +
     `GuessWho-MacCatalyst.entitlements` (`<TeamID>.` form), selected by
     `CODE_SIGN_ENTITLEMENTS[sdk=macosx*]`.
   - Extension: `GuessWhoLinkedIn.entitlements` (iOS) +
     `GuessWhoLinkedIn-MacCatalyst.entitlements` (`<TeamID>.`), same per-SDK
     override. **App Group only** — no iCloud, no Contacts.

> **Gotcha (cost real debugging time):** the **extension target has its own
> xcconfigs** — `App/Config/GuessWhoLinkedIn-Shared.xcconfig` plus the
> per-configuration `GuessWhoLinkedIn-Debug.xcconfig` / `GuessWhoLinkedIn-Release.xcconfig`
> — separate from the app's. The extension's App Group id is written out
> literally in those per-config files and must be kept **byte-identical** to the
> app's `GUESSWHO_APP_GROUP` for the same configuration (the app's live in
> `GuessWho-Debug.xcconfig` / `GuessWho-Release.xcconfig`). If they ever diverge,
> on Catalyst the extension and app resolve **different containers** → the app
> reports "No pending-handoff.json". The extension's Debug/Release `buildSettings`
> in `App/GuessWho.xcodeproj/project.pbxproj` are intentionally **empty** (the
> per-config xcconfig is wired as each configuration's `baseConfigurationReference`)
> — do not re-add id settings there; edit the per-config xcconfig instead. Verify
> the built bundles:
> ```sh
> plutil -extract GuessWhoAppGroup raw \
>   "$BUILT/GuessWho.app/Contents/Info.plist"
> plutil -extract GuessWhoAppGroup raw \
>   "$BUILT/GuessWho.app/Contents/PlugIns/GuessWhoLinkedIn.appex/Contents/Info.plist"
> # both must print the SAME id on a given platform.
> ```

## Debug vs. Release identifiers

Debug intentionally uses the same production bundle id, App Group, iCloud
container, and entitlement files as Release so local Xcode builds exercise the
same Apple-approved capabilities (including Contacts notes access). Installing a
Debug build replaces the Release/TestFlight app for that bundle id. The
user-visible names still carry a "Debug" suffix, and the wake scheme carries a
`-debug` suffix (hyphenated, per URL-scheme convention):

| Identifier | Release | Debug |
| --- | --- | --- |
| App bundle id | `com.milestonemade.guesswho` | `com.milestonemade.guesswho` |
| Extension bundle id | `com.milestonemade.guesswho.safari` | `com.milestonemade.guesswho.safari` |
| App Group (iOS) | `group.com.milestonemade.guesswho` | `group.com.milestonemade.guesswho` |
| App Group (Catalyst) | `T68Z94627S.com.milestonemade.guesswho` | `T68Z94627S.com.milestonemade.guesswho` |
| iCloud container | `iCloud.com.milestonemade.guesswho` | `iCloud.com.milestonemade.guesswho` |
| App display name | `GuessWho` | `GuessWho Debug` |
| Extension display name¹ | `GuessWho LinkedIn` | `GuessWho LinkedIn Debug` |
| Wake scheme | `guesswho-linkedin` | `guesswho-linkedin-debug` |

¹ Covers both the appex `CFBundleDisplayName` **and** the web-extension
`manifest.json` `name`/`action.default_title` — Safari surfaces the manifest
name in its Extensions list / permission prompts and `default_title` as the
toolbar-button tooltip. The manifest is generated at build time (see
[Target wiring](#target-wiring--provisioning-notes)) because Xcode copies
resources verbatim and JSON can't interpolate build settings.

**How the ids are wired (per-target, per-configuration xcconfigs):**

Each target has a config-invariant `*-Shared.xcconfig` plus a `-Debug` and a
`-Release` xcconfig that `#include` it and write out the identifiers **literally**
(no composing/suffix variable). Each per-config file is wired as that
target+configuration's `baseConfigurationReference` in the project:

- App — `GuessWho-Shared.xcconfig` (config-invariant) + `GuessWho-Debug.xcconfig`
  / `GuessWho-Release.xcconfig` (literal `PRODUCT_BUNDLE_IDENTIFIER`,
  `GUESSWHO_APP_GROUP` both platform forms, `GUESSWHO_ICLOUD_CONTAINER`,
  `GUESSWHO_DISPLAY_NAME`, `GUESSWHO_LINKEDIN_URL_SCHEME`, and
  `CODE_SIGN_ENTITLEMENTS`).
- Extension — `GuessWhoLinkedIn-Shared.xcconfig` + `GuessWhoLinkedIn-Debug.xcconfig`
  / `GuessWhoLinkedIn-Release.xcconfig` (literal extension `PRODUCT_BUNDLE_IDENTIFIER`,
  `GUESSWHO_APP_GROUP`, `GUESSWHO_EXTENSION_DISPLAY_NAME`,
  `GUESSWHO_LINKEDIN_URL_SCHEME`, `CODE_SIGN_ENTITLEMENTS` — App Group only). The
  wake scheme must stay **byte-identical** to the app's for the same
  configuration, exactly like the App Group id. The extension
  bundle id stays prefixed by the app id (`…guesswho.safari`), an Apple
  requirement for app extensions.
- No identifier settings live at the **project** level (`Project-Debug/Release.xcconfig`)
  or inline in the project file's target `buildSettings` — the per-config xcconfigs
  are the single source of truth. When changing an id, update both the app's and
  the extension's matching per-config file (and the corresponding entitlement
  file) together so the three ids and the App Group stay in lockstep.
- Entitlement `.plist` files can't interpolate build settings, so the ids are
  baked into the file content. Debug and Release point at the same entitlement
  files to keep capability behavior identical.
- The iCloud container is read at runtime from the `GuessWhoiCloudContainer`
  Info.plist key via `ICloudContainer.id` (mirroring how `AppGroup.id` reads
  `GuessWhoAppGroup`), so the runtime lookup in `SyncService` always matches the
  signed entitlement.

> **Portal prerequisite:** the `group.`-prefixed App Group and the iCloud
> container must be **registered in the Apple Developer portal** to be
> provisioned (the `<TeamID>.` Catalyst App Group form is self-authorizing and
> needs no registration). Debug and Release both use the production App Group,
> iCloud container, and entitlement files, so there are no separate Debug portal
> identifiers to register.

## The entitlement split (app does the heavy work)

The extension does **parsing + transport only**; the **app process** does match
/ diff / save, because that needs Contacts + the iCloud sidecar — entitlements
the app already holds and the extension deliberately does not. This keeps the
extension's permission/review footprint minimal.

- **App** entitlements: iCloud (CloudDocuments + ubiquity container), Contacts,
  Calendars, App Group, app-sandbox.
- **Extension** entitlements: App Group + app-sandbox **only**.

## Match → diff → confirm → save (app side)

Once the app drains the parked payload, the whole match/diff/confirm/save flow
runs in-process — this is **built and working end-to-end** for a matched
contact. `GuessWhoSceneDelegate.handleLinkedInHandoff(urlContexts:entry:)` does:

1. **Decode** the `{ stampedBy, payload }` envelope into the package-vended
   `LinkedInProfile` (`Sources/GuessWhoSync/LinkedInProfile.swift`).
2. **Match** — `ContactsRepository.matchLinkedIn(profile:)` runs
   **LinkedIn-URL → email → display-name** in priority order and returns the
   first non-empty tier. *All* matching logic is package-side; the app owns no
   rules. URL matching is scheme/`www.`/slug-insensitive via
   `LinkedInURL` (`Sources/GuessWhoSync/LinkedInURL.swift`).
3. **Diff** — `LinkedInDiff.rows(existing:incoming:existingSidecar:)`
   (`App/GuessWho/LinkedInDiff.swift`) builds the per-field before/after rows
   (presentation only). Emails/websites **merge, never replace** (the right
   column shows the resulting set); URL dedup is scheme-insensitive; the
   internal `guesswho://contact/<uuid>` identity URL is hidden from the
   Websites column (display-only — the save still merges onto the *real*
   `urlAddresses`, never reconstructs it from the filtered set).
   Headline/About/Location read their existing value from the named sidecar
   fields so a re-import marks unchanged rows. The Headline row carries the
   **raw** title/bio line; Job title/Organization come from the parser's
   `title`/`org`, which prefer the Experience section's current position
   (structured, works for any headline) and fall back to splitting the
   headline as `"<Title> at <Org>"`. The probe always scrolls the full page
   to mount every lazy section before re-parsing (see the content-script row
   above), so an unrendered Experience is rare; if it *still* isn't there
   *and* the headline is free-form ("Principal AI Consultant | Driving…"),
   the Headline row is the only carrier of that text.
4. **Confirm** — `LinkedInConfirmView` (`App/GuessWho/LinkedInConfirmView.swift`),
   hosted in a `UIHostingController` form sheet: existing-left / LinkedIn-right,
   a checkbox per row (all on by default), unchanged rows de-emphasized.
   Save applies only the checked fields; Cancel writes nothing.
5. **Save** — `ContactsRepository.applyLinkedIn(profile:to:fields:)` owns the
   merge + save rules. CNContact fields (name/jobTitle/organization/emails/
   websites/LinkedIn social profile) merge-save; Headline/About/Location upsert
   as named `"LinkedIn …"`-prefixed sidecar fields (not append-only notes, so a
   re-import updates rather than duplicates). After `applyLinkedIn` returns, the scene
   delegate posts the app-layer `.linkedInImportDidSave` notification so an open
   `ContactDetailView` reloads (the package never posts app notifications).

Both formerly-future pieces of this flow shipped 2026-07-02:

- **No match → create-then-edit.** When `matchLinkedIn` returns nothing, the
  scene delegate CREATES the contact immediately via
  `ContactsRepository.createContact` seeded by the package's
  `LinkedInContactSeed` (PersonNameComponents name split, job title/org,
  deduped emails/websites, and the LinkedIn username slug as a social
  profile), attaches the extras a CN card can't hold — headline/about/
  location and the photo — through `applyLinkedIn`, then opens the standard
  `ContactDetailView` in the detail column already in edit mode
  (`startsInEditMode`). Same create-then-edit shape as the People list's "+"
  button; there is no separate new-contact form, and deleting the card is the
  undo.
- **Photo write path.** `.photo` routes through
  `ContactsRepository.setContactPhoto` inside `applyLinkedIn`: replacing an
  existing photo first snapshots the replaced bytes into the single-slot
  `previousPhoto` `.blob` (see the note at the end), and the write is skipped
  entirely — no save, no snapshot — when the incoming bytes equal the current
  photo (a re-import) or the payload's data URL doesn't decode.

See [`plans/linkedin-match-diff-confirm.md`](../plans/linkedin-match-diff-confirm.md)
for the field-by-field storage split and the build order.

## Debugging / logging

Both processes log their resolved App Group id and the file path, so a mismatch
is visible in Console:

- **Extension** — subsystem `com.milestonemade.guesswho.safari`, category
  `handoff`: `EXTENSION resolved App Group id=…`, `park: writing to …`,
  `park: wrote N bytes OK …`.
- **App** — subsystem `com.milestonemade.guesswho`, category `linkedin-handoff`:
  `APP resolved App Group id=…`, `read: looking for …`.

The `EXTENSION resolved … id=` and `APP resolved … id=` lines must be
**identical**, and the `park: writing to …` path must match `read: looking for …`.

To see **what the parser captured** for a given profile (e.g. "why is the
headline missing?"), there are two payload dumps, one per side of the boundary:

- **Page console** — `content.js` logs `[GuessWho] parse result:` (full parsed
  JSON, photo bytes elided) in the LinkedIn tab's Web Inspector console. It
  includes the `_topCardLines` debug field: the raw top-card `<p>` lines
  *before* headline/location classification, which pinpoints whether a miss is
  a DOM-walking problem or a classification problem.
- **App log** — after decoding the parked payload, the scene delegate logs
  `decoded payload: {…}` (photo elided) under `app.linkedin-handoff`, so "did
  field X arrive in the app?" is answerable from `app.log` alone.

## Runtime validation (needs a human)

The build/embed/entitlement/identifier wiring is verifiable headlessly
(`xcodebuild` + `plutil`/`codesign` on the products). The actual handoff
round-trip is **not** — it needs Safari + a real tab:

1. Run the Catalyst app once so LaunchServices registers the appex and the
   wake scheme (`guesswho-linkedin`, or `guesswho-linkedin-debug` for a Debug
   build).
2. Safari → Settings → Extensions → enable **GuessWho LinkedIn** — a Debug
   build shows up as **GuessWho LinkedIn Debug** (a local dev build may need
   "Allow unsigned extensions").
3. Open a real `https://www.linkedin.com/in/<slug>` tab, click the popup →
   **Send to GuessWho**.
4. Confirm the app surfaces the payload, with matching ids in Console.

Status (2026-06-26): **proven end-to-end on Mac Catalyst, no permission
prompts.**

## Target wiring & provisioning notes

How the target is wired into `App/GuessWho.xcodeproj` (objectVersion 77,
file-system synchronized groups, matching the app target):

- The `GuessWhoLinkedIn` folder is a **synchronized root group**; an exception
  set keeps `Info.plist`, the entitlements files, and `SPIKE.md`-era docs out of
  the bundled web resources. `Resources/manifest.json` is also excluded: a
  **Generate manifest.json** script phase (after Copy Bundle Resources, its only
  producer) copies it into the appex, rewriting `name` and
  `action.default_title` from `GUESSWHO_EXTENSION_DISPLAY_NAME` so Debug and
  Release read differently everywhere Safari shows the extension.
- The app target has an **Embed Foundation Extensions** copy-files phase
  (`dstSubfolderSpec = 13`) plus a target dependency on the extension, so the
  `GuessWho` scheme builds and embeds the appex automatically
  (`…/PlugIns/GuessWhoLinkedIn.appex`).
- The extension's `Info.plist` carries the `NSExtension` dict
  (`NSExtensionPointIdentifier = com.apple.Safari.web-extension`,
  `NSExtensionPrincipalClass = $(PRODUCT_MODULE_NAME).SafariWebExtensionHandler`).
- The extension's build configs use the per-configuration
  `Config/GuessWhoLinkedIn-Debug.xcconfig` / `Config/GuessWhoLinkedIn-Release.xcconfig`
  as their base config; each `#include`s `GuessWhoLinkedIn-Shared.xcconfig`,
  which in turn `#include`s `Config/SharedVersion.xcconfig`, so the extension's
  version tracks the app's transitively. The extension has its **own** xcconfig
  stack, separate from the app's `GuessWho-*.xcconfig` — see the App Group gotcha
  above.

**App Group provisioning for a clean machine / CI:** automatic signing registers
`group.com.milestonemade.guesswho` (iOS) during a local build, and the Catalyst
`<TeamID>.` form needs no registration. For CI or a fresh machine, ensure the
`group.`-prefixed App Group exists on the Apple Developer portal and is enabled
on both App IDs (`com.milestonemade.guesswho` and
`com.milestonemade.guesswho.safari`); `REGISTER_APP_GROUPS = YES` drives the
profile fetch. Debug uses those same production identifiers — see
[Debug vs. Release identifiers](#debug-vs-release-identifiers).

## Still future work

Real LinkedIn DOM parsing, in-session photo-byte fetch, the "Contact info"
overlay, contact matching, the before/after diff/confirm UI, the no-match →
new-contact editor, and the photo write path have all **shipped** (see
[The three pieces](#the-three-pieces) and
[Match → diff → confirm → save](#match--diff--confirm--save-app-side)). What
remains:

- **The iOS extension target.** Only the Mac Catalyst path is proven
  end-to-end; the extension is authored to port (MV3 non-persistent worker,
  phone-sized popup) but the iOS target + provisioning aren't wired yet.

See [`plans/linkedin-safari-extension.md`](../plans/linkedin-safari-extension.md)
for the overall feature plan.

**Built (2026-06-27):** the `.blob` sidecar field type + previous-photo
snapshot. A `.blob` field stores a small pointer to an AES-GCM-encrypted `.dat`
neighbor file under the same iCloud root (the key lives in the synchronizable
keychain). The contact-image write path (`ContactsRepository.setContactPhoto`)
snapshots the replaced photo into a single-slot `previousPhoto` `.blob`; a
reference-counting `sweepOrphanBlobs()` reclaims unreferenced `.dat`s. v1
guarantees capture only (no revert UI yet).
