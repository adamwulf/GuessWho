# LinkedIn Safari Web Extension & the extension↔app handoff

This document is the source of truth for how the **GuessWho LinkedIn** Safari
Web Extension works, how it communicates with the GuessWho app, and the App
Group rules that differ between iOS and Mac Catalyst. Read it before touching
the extension target, the App Group identifiers, the entitlements, or the
handoff code.

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
| Content script | `App/GuessWhoLinkedIn/Resources/content.js` | Runs in `linkedin.com/in/*` tabs. Reads the DOM (the real parser lands in a later step; today it returns a minimal probe). |
| Background service worker | `App/GuessWhoLinkedIn/Resources/background.js` | The **only** place that can talk to native. Relays content/popup messages to the native handler via `sendNativeMessage`. Non-persistent (MV3 `service_worker`) — required on iOS, fine on macOS. |
| Popup | `App/GuessWhoLinkedIn/Resources/popup.{html,js}` | User-facing toolbar UI. Orchestrates: probe the tab → hand off to native → open the wake URL. Sized for a phone sheet so it ports to iOS. |
| Native handler | `App/GuessWhoLinkedIn/SafariWebExtensionHandler.swift` | Runs in the **extension process**. Parks the payload in the App Group and returns the wake URL. Holds **App Group only** — no Contacts, no iCloud. |
| App receiver | `App/GuessWho/GuessWhoSceneDelegate.swift` | Runs in the **app process**. Receives the wake URL, drains the parked payload, and (eventually) does match / diff / save. |

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
   │  ack {received, wakeURL:"guesswho-linkedin://handoff"}
   ▼
popup.js  ── window.location.href = wakeURL ──▶  GuessWhoSceneDelegate           (APP process)
                                                  │ scene(_:openURLContexts:) /
                                                  │ willConnectTo cold-launch drain
                                                  ▼ reads + DELETES pending-handoff.json
                                                    → match / diff / save (later steps)
```

Concrete contract:

- **Parked file:** `pending-handoff.json` (`handoffFilename`) in the App Group
  container. Written by `SafariWebExtensionHandler.parkPayload(_:)` with
  `{ "payload": …, "stampedBy": "extension" }`.
- **Wake URL:** `guesswho-linkedin://handoff`. Registered in
  `App/GuessWho/Info.plist` under `CFBundleURLTypes` (scheme `guesswho-linkedin`).
  - **Do not collide** with the unrelated `guesswho://contact/<uuid>` identity
    URL — that is a CNContact data-storage value (a `SidecarKey` payload), not a
    launch scheme. The handoff receiver filters strictly on
    `scheme == "guesswho-linkedin"`.
- **Receiver:** `GuessWhoSceneDelegate.handleLinkedInHandoff(urlContexts:)`,
  reached from both `scene(_:openURLContexts:)` (running app) and a
  `connectionOptions.urlContexts` drain in `willConnectTo` (cold launch). It
  **reads and immediately deletes** the file (replay-proof) and caps the read
  size (`handoffMaxBytes`) so it never loads an unbounded/hostile file.

The App Group is used **only** for this ephemeral handoff. It is NOT synced
storage — the synced GuessWho sidecar lives in the **iCloud ubiquity container**
(`iCloud.com.milestonemade.guesswho` for Release,
`iCloud.com.milestonemade.guesswho.debug` for Debug), a different container
entirely. The container id is build-driven the same way the App Group is — see
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

Debug builds append a `.debug` suffix to the name (`group.com.milestonemade.guesswho.debug`
/ `T68Z94627S.com.milestonemade.guesswho.debug`) so a debug install never shares
a container with a release install — see
[Debug vs. Release identifiers](#debug-vs-release-identifiers).

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

1. **xcconfig var** — `GUESSWHO_APP_GROUP`, composed from a shared base id and
   the per-configuration `GUESSWHO_ID_SUFFIX` (`.debug` in Debug, empty in
   Release), with a `[sdk=macosx*]` override. Defined in
   `App/Config/GuessWho-Shared.xcconfig` for the app and
   `App/Config/GuessWhoLinkedIn-Shared.xcconfig` for the extension:
   ```
   GUESSWHO_BASE_ID = com.milestonemade.guesswho
   GUESSWHO_APP_GROUP = group.$(GUESSWHO_BASE_ID)$(GUESSWHO_ID_SUFFIX)
   GUESSWHO_APP_GROUP[sdk=macosx*] = $(DEVELOPMENT_TEAM).$(GUESSWHO_BASE_ID)$(GUESSWHO_ID_SUFFIX)
   ```
2. **Info.plist key** — both the app's and the extension's `Info.plist` carry
   `GuessWhoAppGroup = $(GUESSWHO_APP_GROUP)`.
3. **Swift code** — `SafariWebExtensionHandler.appGroupID` and
   `GuessWhoSceneDelegate.handoffAppGroupID` read that Info.plist key
   (`Bundle.main.object(forInfoDictionaryKey: "GuessWhoAppGroup")`), never a
   hardcoded literal. So the runtime container always matches the entitlement.
4. **Entitlements files** — per-target, per-SDK, **and per-configuration** (the
   id is baked into the plist content, so Debug and Release need separate files,
   selected by `GUESSWHO_ENTITLEMENTS_VARIANT` — `-Debug` vs empty):
   - App: `GuessWho.entitlements` / `GuessWho-Debug.entitlements` (iOS, `group.`
     form) + `GuessWho-MacCatalyst.entitlements` /
     `GuessWho-MacCatalyst-Debug.entitlements` (`<TeamID>.` form), selected by
     `CODE_SIGN_ENTITLEMENTS[sdk=macosx*]`.
   - Extension: `GuessWhoLinkedIn.entitlements` /
     `GuessWhoLinkedIn-Debug.entitlements` (iOS) +
     `GuessWhoLinkedIn-MacCatalyst.entitlements` /
     `GuessWhoLinkedIn-MacCatalyst-Debug.entitlements` (`<TeamID>.`), same per-SDK
     override. **App Group only** — no iCloud, no Contacts.

> **Gotcha (cost real debugging time):** the **extension target does NOT inherit
> `GuessWho-Shared.xcconfig`** — that xcconfig is wired to the *app* target. The
> extension has its **own** target xcconfig, `App/Config/GuessWhoLinkedIn-Shared.xcconfig`,
> which composes `GUESSWHO_APP_GROUP` from the same `GUESSWHO_BASE_ID` +
> per-configuration `GUESSWHO_ID_SUFFIX` so the app and extension always resolve
> the **same** App Group on a given platform/configuration. (The
> `GUESSWHO_ID_SUFFIX` / `GUESSWHO_ENTITLEMENTS_VARIANT` vars are defined at the
> *project* level in `Project-Debug/Release.xcconfig`, so they reach the
> extension's target xcconfig via Xcode's layered resolution even though that
> file does not `#include` them.) The extension's Debug/Release `buildSettings`
> in `App/GuessWho.xcodeproj/project.pbxproj` are intentionally **empty** — do
> not re-add id settings there; edit `GuessWhoLinkedIn-Shared.xcconfig` instead.
> If `GUESSWHO_APP_GROUP` ever expanded to **empty** in the extension's
> Info.plist, the handler would fall back to the iOS literal and on Catalyst the
> extension and app would resolve **different containers** → the app reports "No
> pending-handoff.json". Verify the built bundles:
> ```sh
> plutil -extract GuessWhoAppGroup raw \
>   "$BUILT/GuessWho.app/Contents/Info.plist"
> plutil -extract GuessWhoAppGroup raw \
>   "$BUILT/GuessWho.app/Contents/PlugIns/GuessWhoLinkedIn.appex/Contents/Info.plist"
> # both must print the SAME id on a given platform.
> ```

## Debug vs. Release identifiers

A Debug install must be able to coexist with a Release/TestFlight install on the
same device without sharing data. All three identity-bearing ids therefore carry
a `.debug` suffix in Debug builds and are bare in Release:

| Identifier | Release | Debug |
| --- | --- | --- |
| App bundle id | `com.milestonemade.guesswho` | `com.milestonemade.guesswho.debug` |
| Extension bundle id | `com.milestonemade.guesswho.safari` | `com.milestonemade.guesswho.debug.safari` |
| App Group (iOS) | `group.com.milestonemade.guesswho` | `group.com.milestonemade.guesswho.debug` |
| App Group (Catalyst) | `T68Z94627S.com.milestonemade.guesswho` | `T68Z94627S.com.milestonemade.guesswho.debug` |
| iCloud container | `iCloud.com.milestonemade.guesswho` | `iCloud.com.milestonemade.guesswho.debug` |

**How the suffix is applied (single source of truth):**

- `GUESSWHO_ID_SUFFIX` is defined per-configuration at the **project** level —
  `.debug` in `Project-Debug.xcconfig`, empty in `Project-Release.xcconfig`. Being
  project-level, it reaches every target's xcconfig via Xcode's layered
  resolution regardless of that target's `baseConfigurationReference`.
- `GUESSWHO_BASE_ID` (`com.milestonemade.guesswho`) lives in the target xcconfigs;
  the bundle id, `GUESSWHO_APP_GROUP`, and `GUESSWHO_ICLOUD_CONTAINER` are all
  composed as `…$(GUESSWHO_BASE_ID)$(GUESSWHO_ID_SUFFIX)…` so the three ids can
  never drift apart. The extension bundle id inserts the suffix before the
  `.safari` leaf so it stays prefixed by the app id (an Apple requirement for
  app extensions).
- Entitlement `.plist` files can't interpolate build settings, so the ids are
  baked into the file content and Debug/Release get separate files, selected by
  `GUESSWHO_ENTITLEMENTS_VARIANT` (`-Debug` vs empty) in `CODE_SIGN_ENTITLEMENTS`.
- The iCloud container is read at runtime from the `GuessWhoiCloudContainer`
  Info.plist key via `ICloudContainer.id` (mirroring how `AppGroup.id` reads
  `GuessWhoAppGroup`), so the runtime lookup in `SyncService` always matches the
  signed entitlement.

> **Portal prerequisite:** the `group.`-prefixed App Group and the iCloud
> container must be **registered in the Apple Developer portal** to be
> provisioned (the `<TeamID>.` Catalyst App Group form is self-authorizing and
> needs no registration). The `.debug` App Group and `iCloud.…guesswho.debug`
> container must therefore be added to the portal before Debug **device** or
> **Catalyst** signing will succeed. Debug **simulator** builds and all Release
> builds are unaffected (the simulator does not enforce these entitlements).

## The entitlement split (app does the heavy work)

The extension does **parsing + transport only**; the **app process** does match
/ diff / save, because that needs Contacts + the iCloud sidecar — entitlements
the app already holds and the extension deliberately does not. This keeps the
extension's permission/review footprint minimal.

- **App** entitlements: iCloud (CloudDocuments + ubiquity container), Contacts,
  Calendars, App Group, app-sandbox.
- **Extension** entitlements: App Group + app-sandbox **only**.

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

## Runtime validation (needs a human)

The build/embed/entitlement/identifier wiring is verifiable headlessly
(`xcodebuild` + `plutil`/`codesign` on the products). The actual handoff
round-trip is **not** — it needs Safari + a real tab:

1. Run the Catalyst app once so LaunchServices registers the appex and the
   `guesswho-linkedin` scheme.
2. Safari → Settings → Extensions → enable **GuessWho LinkedIn** (a local dev
   build may need "Allow unsigned extensions").
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
  the bundled web resources.
- The app target has an **Embed Foundation Extensions** copy-files phase
  (`dstSubfolderSpec = 13`) plus a target dependency on the extension, so the
  `GuessWho` scheme builds and embeds the appex automatically
  (`…/PlugIns/GuessWhoLinkedIn.appex`).
- The extension's `Info.plist` carries the `NSExtension` dict
  (`NSExtensionPointIdentifier = com.apple.Safari.web-extension`,
  `NSExtensionPrincipalClass = $(PRODUCT_MODULE_NAME).SafariWebExtensionHandler`).
- The extension's build configs use `Config/SharedVersion.xcconfig` as their base
  config so its version tracks the app's; **but they do not inherit
  `GuessWho-Shared.xcconfig`** — see the App Group gotcha above.

**App Group provisioning for a clean machine / CI:** automatic signing registers
`group.com.milestonemade.guesswho` (iOS) during a local build, and the Catalyst
`<TeamID>.` form needs no registration. For CI or a fresh machine, ensure the
`group.`-prefixed App Group exists on the Apple Developer portal and is enabled
on both App IDs (`com.milestonemade.guesswho` and
`com.milestonemade.guesswho.safari`); `REGISTER_APP_GROUPS = YES` drives the
profile fetch.

## Out of scope here (later build steps)

Real LinkedIn DOM parsing (semantic-anchor selectors), in-session photo-byte
fetch, the "Contact info" modal, contact matching, the before/after diff UI, and
the iOS target. See
[`plans/linkedin-safari-extension.md`](../plans/linkedin-safari-extension.md).

**Built (2026-06-27):** the `.blob` sidecar field type + previous-photo
snapshot. A `.blob` field stores a small pointer to an AES-GCM-encrypted `.dat`
neighbor file under the same iCloud root (the key lives in the synchronizable
keychain). The contact-image write path (`ContactsRepository.setContactPhoto`)
snapshots the replaced photo into a single-slot `previousPhoto` `.blob`; a
reference-counting `sweepOrphanBlobs()` reclaims unreferenced `.dat`s. v1
guarantees capture only (no revert UI yet).
