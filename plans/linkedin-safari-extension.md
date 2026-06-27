# Plan: LinkedIn enrichment via Safari Web Extension (macOS first)

## Status (2026-06-26)

Planning only. No app, package, or Xcode-project changes have been made.

**Reviewed (2026-06-26).** Two independent reviewers verified the plan's claims
against the real tree. Both issued REQUEST-CHANGES on the same core flaw, now
fixed in this revision: the original draft conflated an **App Group** with the
**iCloud ubiquity container** where the synced sidecar actually lives
(`SyncService.swift:581`). Corrections folded in: (1) the native handler runs in
the **extension process** and the **app process** now does match/diff/save via a
handoff; (2) the `.blob` `.dat` must live under the iCloud root and the store's
`.json`-only enumeration must be **extended** (not inherited free); (3) whole-cell
LWW merge orphans a loser's `.dat`, so a **reference-counting sweep** + fresh
per-write UUID are required; (4) `licdn.com` host permission, the absent
social-profile-URL lookup primitive, and the image-write reality
(`apply()`/`saveContact` skip image data) are all now reflected. The verified
*positives* — DOM/semantic-anchor/fixtures approach, `.blob`-as-file-pointer
shape, product-principle/identity-boundary alignment — were left intact.

This plan covers a **macOS-first** Safari Web Extension, bundled inside the
GuessWho app, that reads the LinkedIn profile in the user's *already
authenticated* Safari tab, matches it to a GuessWho contact, shows a
before/after diff, and lets the user **save** or **discard** the enrichment.

iOS/iPadOS is explicitly **out of scope for v1** but the extension code is
authored to iOS's stricter constraints so a second target is cheap to add
later (see "iOS portability" below).

**v1 scope decided (2026-06-26):** parse Name, Photo (bytes fetched in-session),
Job title, Current organization, Bio, Location, **and** the "Contact info" modal
(emails / webpages / profile URL). Photo write is built in v1. v1 **enriches
existing contacts only** — creating a brand-new contact from a profile is
**phase 2**. See "Decisions made" and "Suggested build order."

## Why an extension (vs. an API or server-side fetch)

- A direct server-side fetch of `https://www.linkedin.com/in/<slug>/` returns
  **HTTP 999** (LinkedIn's anti-bot block). Confirmed on 2026-06-26 against
  `https://www.linkedin.com/in/adamwulf/` — no body, no OpenGraph tags, nothing.
- The official LinkedIn API's free tier only returns name/photo/headline **for
  the logged-in user who authorizes the app**; it cannot look up an arbitrary
  third party by profile URL. Third-party lookup needs Partner/MDP approval
  (selective, slow, enterprise-priced).
- A Safari Web Extension runs **inside the user's own authenticated session**,
  reading the DOM of a page the user is already viewing. The 999 problem
  disappears because we are not fetching as a bot — we are reading the rendered
  page the user already loaded.

### Posture / ToS framing (design constraint, not legal advice)

Keep the feature **user-initiated and user-confirmed**, never a silent
background harvester:

- Only acts on the **active tab the user is viewing**, on explicit user action
  (toolbar click), never auto-scraping in the background or pre-fetching other
  profiles.
- Always shows a **before/after diff** and requires explicit **Save**; nothing
  is written without a click.
- Reads only the fields below; does not crawl connections, walk the graph, or
  store raw HTML.

This keeps us in a much lighter posture than API scraping (user reading their
own authenticated page, choosing to copy a few fields into their own contact),
but App Store review *will* scrutinize a LinkedIn-reading extension — keep host
permissions tight and the value-prop user-driven.

## How this maps onto the existing GuessWho data model

The fields we want already exist on `Contact` (`Sources/GuessWhoSync/Contact.swift`)
— no new model surface for most of them:

| LinkedIn field        | GuessWho destination                              | Notes |
|-----------------------|---------------------------------------------------|-------|
| Name                  | `givenName` / `familyName` (split heuristically)  | Used for **matching**, rarely overwritten |
| Job title             | `Contact.jobTitle`                                | direct |
| Current organization  | `Contact.organizationName`                        | direct |
| City / state / location | `Contact.postalAddresses` (a `LabeledPostalAddress`, label e.g. "LinkedIn") OR a sidecar field | LinkedIn gives a free-text locality string ("Austin, Texas Area"), not a structured address — see "Location" below |
| Bio / about string    | A **sidecar `ContactNote`** via `addNote(for:body:)` | No CNContact "bio" field exists; bio is GuessWho-only data → sidecar, consistent with the product principle |
| Profile photo         | Contact image bytes (**in v1**)                   | Bytes fetched **inside the content script** (in-session), passed to native; needs a net-new package **write** path — see "Photo write gap" |
| Profile URL           | `Contact.socialProfiles` (`LabeledSocialProfile`, service "LinkedIn") | Already modeled in `SocialProfile.swift`; can also seed matching |
| Webpages / emails (Contact info modal) | `Contact.urlAddresses` / `Contact.emailAddresses` | Behind a **"Contact info" button** → modal; requires a click-then-parse interaction, not a static DOM read — see "Contact info modal" |

### Matching primitives that already exist

`ContactsRepository` already exposes everything the match step needs:

- `contactIDs(named displayName:)` and `lookupByDisplayName()` — name match.
- `contactsReferencing(...)`, `contact(id:)`, `editableContact(id:)` — resolve + edit.
- `saveContact(_:for:)` — write the enriched contact back.
- `addNote(for:body:)` — store the bio as a sidecar note.
- `socialProfiles` on `Contact` — match/seed on an existing LinkedIn URL.

### Real gaps to flag up front

1. **Photo write path is net-new package work (in scope for v1).** The
   contact-profile-photos plan (`plans/contact-profile-photos.md`) covers
   **loading** image bytes only (`contactPhotoData(for:kind:)` — note this read
   path is **already implemented**, `ContactsRepository.swift:196`). There is no
   write API, and it's **more than "mirror the read side" (post-review):**
   - `CNContactStoreAdapter` deliberately **skips image data on save** —
     `apply()` never writes `imageData` (around lines 620–624), specifically to
     preserve round-trips. So a write path can't just flip a flag.
   - The **bulk** fetch keys omit the image **bytes** (`imageData` /
     `thumbnailImageData`) — but `CNContactImageDataAvailableKey` *is* present;
     the byte keys live in the separate lazy image/thumbnail key sets. (Earlier
     plan phrasing "keys omits image-data keys" was loose.)
   - Therefore the write path needs a **dedicated fetch-with-image-keys**
     (re-fetch the `CNContact` requesting `imageData`), set the bytes, and issue
     a **separate save request** that explicitly includes image data — distinct
     from the normal `saveContact` round-trip. This is the **largest single item**
     in the feature; the conservative framing is correct.

   **Decision (2026-06-26): photo is in v1.** Build this write path; don't defer.
   - **Photo bytes are fetched *inside* the content script**, not by the native
     side from the URL. Rationale (per user): the photo `src` is a
     `media.licdn.com` CDN URL that may reject out-of-browser fetches the same
     way the profile page returns 999. Fetching from the content script reuses
     the user's authenticated session/cookies, so it succeeds where a native
     `URLSession` fetch might not. The content script `fetch()`es the image,
     converts to bytes/base64, and passes it through native messaging.
   - **Message-size caveat:** image bytes can be large and the native-messaging
     channel is bounded by `NSExtensionContext`. Mitigate by fetching the
     **smallest adequate** image (LinkedIn serves multiple sizes in `srcset` —
     pick a ~200–400px variant for a contact thumbnail, not the full-res), and
     by writing the bytes to the **shared App Group container** and passing only
     a filename/handle through the message if the payload is too big. Decide the
     exact transport during implementation against a real measured payload.
2. **Preserve the previous photo (general rule, not LinkedIn-specific).**
   **Decision (2026-06-26):** whenever GuessWho **replaces** a contact's photo —
   from this LinkedIn flow *or any other future path* — first **save the old
   photo bytes into the sidecar** as a "previous photo" for that contact. This
   is a property of the **contact-image write path itself**, so it lives in the
   package (`GuessWhoSync`), not in the extension — every caller that sets a
   photo gets the snapshot for free. Design notes / sub-decisions needed:
   - **Read-before-write:** the write API must first load the current
     `CNContact` image bytes (the read path from `plans/contact-profile-photos.md`
     already exists) and stash them before overwriting. If there is no current
     photo, there's nothing to snapshot.
   - **Storage shape — decided (2026-06-26): add a `.blob` type to the
     sidecar.** The sidecar has **no binary field type today** —
     `SidecarFieldType` is only `.note` / `.date` / `.checkbox`. Extend it with a
     **`.blob`** case so binary payloads (the previous photo bytes) are a
     first-class sidecar field. This is net-new package work — see the
     "`.blob` sidecar field type" section below for the full surface
     (`SidecarFieldType`, `SidecarField.validate`/`decode`/`makeInnerValue`,
     and how bytes ride in the JSON-in-iCloud envelope without bloating sync).
   - **How many to keep?** Decision needed: keep only the **single** most-recent
     previous photo (overwrite each time), or a **history** of N. Recommend a
     single previous-photo slot for v1 (simplest; revisit if a gallery is wanted).
   - **Surfacing it:** out of scope to *build* UI in this plan, but the stored
     previous photo should be retrievable so a later "revert to previous photo"
     or history view is possible. v1 just guarantees it's **captured**.
   - **Product-principle check:** "previous photo" is plain-language and
     user-facing-safe — it does **not** leak sidecar vocabulary, so it's fine to
     surface later as "previous photo," never as "sidecar photo."
3. **Location is free-text, not structured.** Confirmed from the saved profile:
   the locality renders as a plain string (`Tomball, Texas, United States`) with
   no structured city/state/country split. Either store it verbatim in a sidecar
   field, or parse best-effort into a `PostalAddress`. **Decision: verbatim into
   a sidecar field** for v1 to avoid bad structured data.

### What the saved profile HTML actually shows (verified 2026-06-26)

Inspected `~/Downloads/linkedin/Adam Wulf _ LinkedIn.html` (a logged-in `Cmd-S`
save). Findings that shape the parser:

- **No JSON-LD, no OpenGraph meta tags** on the logged-in page. The only `<meta>`
  tags are CSP/tracking; there is no `og:title` / `og:image` to lean on. (Those
  exist only on the logged-*out* public view, which we never see.)
- **Class names are obfuscated and rotating** (e.g. `_18045a1c f2813a6b
  ccd16393 ae68a123`). The name `<h2>`, the headline, and the location element
  all share similar generated classes — **class-based selectors are useless and
  will rot immediately.**
- **Stable anchors that DO exist:**
  - Page `<title>` = `Adam Wulf | LinkedIn` → reliable full-name source.
  - Profile photo `<img>` has `alt="View Adam Wulf’s profile"` and the
    container has `aria-label="Adam Wulf"` → anchor the photo via
    `img[alt^="View "][alt*="profile"]`, and cross-check the name from the alt.
  - The name renders as an `<h2>` inside the top-card region (not an `<h1>`).
  - Location renders as a sibling text node near the name in the top card
    (`Tomball, Texas, United States`).
- **Implication:** the parser must anchor on **semantic/structural signals**
  (`<title>`, `aria-*`, `alt` text, top-card section landmark, visible-text
  proximity), never on the rotating class names. This is the single most
  important parsing decision and the main driver of long-term brittleness.

## Architecture

> **Critical correction (2026-06-26, post-review):** the
> `SafariWebExtensionHandler` native code runs in the **EXTENSION process**, not
> in the app. And GuessWho's synced data does **not** live in an App Group — the
> sidecar root is the **iCloud ubiquity container**
> (`SyncService.swift:581`: `url(forUbiquityContainerIdentifier:
> "iCloud.com.milestonemade.guesswho")/Documents`), and Contacts is reached
> through `CNContactStore`. So the extension cannot "just call `GuessWhoSync`"
> the way the app does. Two containers, kept distinct from here on:
> - **App Group** (`group.com.milestonemade.guesswho`) — for **ephemeral IPC /
>   handoff** between extension and app (e.g. parking a large photo payload).
>   **Does NOT iCloud-sync.**
> - **iCloud ubiquity container** (`iCloud.com.milestonemade.guesswho`) — where
>   the synced sidecar (and any synced blob `.dat`) actually lives. Only writes
>   here sync.

### Chosen design: thin extension, **hand off the heavy work to the app process**

Rather than bootstrap a full Contacts + iCloud + `GuessWhoSync` stack inside the
extension (which would require giving the extension its own Contacts/Calendar +
iCloud-container entitlements and separate user permission grants — heavy, and a
worse privacy/review story), the extension does only **parsing + transport**, and
the **app process** does match / diff / save. The extension wakes the app via a
handoff and the app surfaces the before/after UI.

```
LinkedIn tab (Safari, user authenticated)
        │  DOM
        ▼
[content script]  parse Name/Title/Org/Bio/Location + fetch photo bytes
                  (in-session) + open Contact-info modal → emails/webpages
        │  browser.runtime.sendMessage()
        ▼
[background script]  (event-driven, non-persistent)
        │  browser.runtime.sendNativeMessage()
        ▼
[SafariWebExtensionHandler.swift]  (native, in the EXTENSION process)
        │  validate/normalize payload; park photo bytes in the App Group
        │  container; hand off to the app (see "extension → app handoff")
        ▼
[GuessWho app process]  match (ContactsRepository) → before/after diff →
                        present UI → on Save: saveContact / addNote /
                        image write / blob snapshot  (Contacts + iCloud here)
```

**Open design sub-question (flag for build):** the exact extension→app handoff
mechanism on Catalyst/iOS. Candidates: a custom URL scheme / universal link that
launches the app with the parked-payload handle; the app observing the App Group
container; or (if we accept the heavier path) the extension itself holding the
Contacts+iCloud entitlements and doing the work. Default to **app-does-the-work**
and pick the wake mechanism during the Part 1 spike. This is now the single
biggest architectural decision in the plan.

Native ↔ JS messaging facts (Apple docs, verified 2026-06-26):

- Content scripts **cannot** message native directly — they message the
  background script (`browser.runtime.sendMessage`), which calls
  `browser.runtime.sendNativeMessage(...)`.
- **Safari ignores the application-identifier argument** to
  `sendNativeMessage` — it always routes to the extension's own
  `SafariWebExtensionHandler`. (Don't design around addressing a specific id.)
- Native receives in `SafariWebExtensionHandler.beginRequest(with:)`, replies via
  `context.completeRequest(returningItems:)`.
- Message size is bounded by `NSExtensionContext`. Text fields go inline. For the
  **photo**, the content script fetches bytes in-session, then they're parked in
  the **App Group** container (ephemeral handoff) and the app picks them up — the
  App Group is the right place for this transient payload (it does not need to
  sync). Pick the smallest adequate `srcset` variant regardless, to stay small.
- **"App need not be running" no longer applies as a feature** — this design
  *intentionally* wakes/brings-forward the app to do the work and show UI.

---

## Part 1 — Xcode project setup (target: doable without the user)

Goal: add a **Safari Web Extension** to the existing
`App/GuessWho.xcodeproj` such that it builds, loads in Safari, and round-trips
a hello-world native message. This is the riskiest "can the agent do it alone"
part because it touches signing/entitlements.

### 1a. Add the extension target

There are two routes; **prefer the converter route** for reproducibility:

- **Route A — `safari-web-extension-converter` (scriptable, preferred).**
  Author the web-extension folder by hand (manifest + JS + popup, see Part 3),
  then run:
  ```sh
  xcrun safari-web-extension-converter <path-to-webext-folder> \
    --project-location <tmp> --app-name GuessWhoLinkedIn --bundle-identifier <id> \
    --no-open --macos-only --force
  ```
  This generates a target + `SafariWebExtensionHandler.swift` + Info.plist
  wiring we then **graft into the existing project** (the converter makes a
  *new* project; we lift its extension target and resources into
  `GuessWho.xcodeproj`). Grafting target settings into an existing `.pbxproj`
  is fiddly; if it fights us, fall back to Route B.
- **Route B — Xcode "Safari Extension App" / "Add Target".** GUI-driven; harder
  to do headlessly. Document the exact steps so the user can do it in ~5 min if
  the agent's `.pbxproj` surgery is too risky.

**Honest constraint:** modifying `GuessWho.xcodeproj/project.pbxproj` by hand to
add a new target, build phases, and entitlements is achievable but error-prone.
The agent should attempt Route A, build after every change, and **stop and hand
the residual GUI steps to the user** rather than leave the project unbuildable.
Per repo convention, after any project/package change, re-resolve packages and
build into local DerivedData.

### 1b. Identity, entitlements & App Group (confirmed against the repo 2026-06-26)

**Real state of the project today:**
- App bundle id: **`com.milestonemade.guesswho`** (`App/Config/GuessWho-Shared.xcconfig`).
- Team: **`T68Z94627S`**, `CODE_SIGN_STYLE = Automatic`.
- Two entitlements files, currently byte-identical:
  `App/GuessWho/GuessWho.entitlements` (iOS/iPadOS) and
  `GuessWho-MacCatalyst.entitlements` (macosx sdk override). Both declare **only**
  iCloud: container/ubiquity `iCloud.com.milestonemade.guesswho` + `CloudDocuments`.
- **No App Group exists yet** — there is no `com.apple.security.application-groups`
  key in either file. Adding one is net-new entitlement work.

**Extension bundle id (decided):** **`com.milestonemade.guesswho.safari`**
(app id + `.safari` suffix).

**App Group identifier — verified against Apple docs (2026-06-26):**
Use a **single** identifier **`group.com.milestonemade.guesswho`** across both
the iOS and Mac Catalyst targets. The earlier "iOS wants `group.`, Mac wants it
without" folk rule is **not quite right** — here is what Apple's
[App Groups Entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.application-groups)
and [Configuring app groups](https://developer.apple.com/documentation/xcode/configuring-app-groups)
actually say:

- The entitlement is available on **iOS, iPadOS, Mac Catalyst (3.0+), macOS,
  tvOS, watchOS** — Catalyst is explicitly supported.
- The **`group.<name>`** format is the **cross-platform** one. Per "Configuring
  app groups," *a container ID must begin with `group.`* and then a custom
  string. This works for iOS **and** Catalyst — no per-platform split needed.
- The **`<TeamID>.<name>`** format (no `group.` prefix) is a **macOS-only
  *alternative*, not a requirement.** Apple: "In macOS, you can **also** create
  app groups … using this identifier format," and "You **don't need to
  register** app groups that use this format." On macOS it additionally makes the
  OS verify the accessing process's code signature carries the same Team ID. It
  only becomes relevant if we ever add a **native (non-Catalyst) macOS** target
  and want to skip developer-account registration — which we don't have.
- **Registration:** the `group.`-prefixed id **must be registered** in the Apple
  Developer account ("You need to register app groups for iOS, iPadOS, …").
  Adding the App Groups capability in Xcode registers it and writes it into the
  entitlements automatically.

**Net:** one id, `group.com.milestonemade.guesswho`, for app + extension on both
iOS and Catalyst. No `[sdk=macosx*]` split for the group id. (A split is only
needed if a future *native* macOS target wants the unregistered `<TeamID>.` form.)
Add the `com.apple.security.application-groups` key to **both** entitlements
files (app: iOS + Catalyst) **and** the new extension's entitlements, consistent
with the existing iCloud-only pattern.

**Steps:**
- In Xcode, add the **App Groups** capability and create
  `group.com.milestonemade.guesswho` (Xcode registers it in the developer account
  and writes the `com.apple.security.application-groups` key for you). Doing it
  via the capability is preferred over hand-editing, because of the registration
  requirement.
- Ensure the key lands in the app's **iOS + Catalyst** entitlements **and** the
  new extension's entitlements (all three reference the same single id).
- Both targets signed with team `T68Z94627S` (Automatic signing).
- Wire the extension target's identity/signing through `App/Config/` xcconfigs to
  match how the app target is configured (the project keeps target settings there).
- Access the **App Group** container (ephemeral handoff only) at runtime via
  `FileManager.containerURL(forSecurityApplicationGroupIdentifier:)` /
  `UserDefaults(suiteName:)` with that id.

**iCloud-container entitlement — separate from the App Group, and which target
needs it depends on the design (post-review):**
- The synced sidecar lives in the **iCloud ubiquity container**
  (`iCloud.com.milestonemade.guesswho`), NOT the App Group. **Only the process
  that writes synced data needs the iCloud container entitlement**
  (`com.apple.developer.icloud-container-identifiers` +
  `ubiquity-container-identifiers` + `CloudDocuments`).
- In the **chosen design (app does the work)**: the **app already has** this
  entitlement; the **extension does NOT need it** — the extension only writes
  ephemeral bytes to the App Group and hands off. ✅ This is a reason to prefer
  the app-does-the-work design.
- If we ever flip to **extension-does-the-work**: the extension target would also
  need the iCloud container entitlement **and** Contacts/Calendar entitlements
  **and** its own user permission grants — substantially heavier. Avoid.

### 1c. Manifest host permissions (keep tight)

- `"host_permissions": ["*://*.linkedin.com/*", "*://*.licdn.com/*"]`.
  **`licdn.com` is required** — profile photos are served from
  `media.licdn.com`, and the in-session `fetch()` of the photo bytes will be
  **CORS-blocked without host permission for that origin** (this would silently
  defeat the whole in-session-fetch rationale). Keep both, nothing wider.
- `"permissions": ["activeTab", "nativeMessaging", "storage"]`.
- Narrow scope = smaller user consent prompt and easier review (but note the
  extra `licdn.com` origin slightly widens the consent prompt — unavoidable for
  the photo path; call it out in onboarding).

### 1d. Build & smoke-test

- Build the app target (Catalyst) per `CLAUDE.md`:
  ```sh
  xcodebuild -project App/GuessWho.xcodeproj -scheme GuessWho \
    -destination 'platform=macOS,variant=Mac Catalyst' \
    -derivedDataPath .build/DerivedData build
  ```
- Run the app once so macOS registers the bundled extension.
- Safari → Settings → Extensions → enable GuessWho; allow on linkedin.com.
- Dev aid: Safari → Develop → **Allow Unsigned Extensions** while iterating.
- **Acceptance for Part 1:** clicking the toolbar button on any linkedin.com tab
  sends a native message and the popup shows a hard-coded reply from
  `SafariWebExtensionHandler`. No parsing yet — just prove the pipe.

---

## Part 2 — Opening Chrome and running scripts on a LinkedIn page

**Important limitation (read first):** in the current agent harness I (Claude)
**cannot** drive Chrome autonomously — both the Claude-in-Chrome MCP tools and
direct execution of the Chrome binary are outside this harness's allow list, and
even an unauthenticated headless Chrome would hit LinkedIn's login wall. So the
Chrome path is a **developer-run selector-prototyping harness**, not something
the agent executes on its own. Selector development is iterative and
human-in-the-loop by nature (you must be logged in).

### Why Chrome at all, if the product is Safari?

Chrome with the **DevTools/CDP remote-debugging port** is the fastest loop for
*developing the DOM selectors* against a **real, logged-in** profile, because
you can attach and run JS expressions repeatedly without rebuilding the Safari
extension. The selectors are plain `document.querySelector` and port 1:1 to the
Safari content script.

### 2a. Launch Chrome with remote debugging (user runs this)

In the GuessWho Claude session, the user can prefix with `!` to run it inline so
output lands in the conversation:

```sh
! open -na "Google Chrome" --args \
  --remote-debugging-port=9222 \
  --user-data-dir="$HOME/.guesswho-chrome-profile"
```

Then **the user logs into LinkedIn once** in that Chrome window (separate
profile dir = isolated cookies; stays logged in across runs). Navigate to
`https://www.linkedin.com/in/adamwulf/`.

### 2b. Run a selector script against the live page

With the debug port open, evaluate JS via CDP. Minimal Node-free approach using
`curl` to the CDP HTTP endpoint to get the page's WebSocket target, then a tiny
script to `Runtime.evaluate`. Practically, a 30-line Node script
(`tools/linkedin-selftest.mjs`, gitignored or under `tools/`) is cleaner:

```js
// tools/linkedin-selftest.mjs  (dev-only; run by the user with node)
import CDP from 'chrome-remote-interface' // npm i -D chrome-remote-interface
const client = await CDP({ port: 9222 })
const { Runtime } = client
const expr = `(${extractProfile.toString()})()`   // extractProfile = the parser below
const { result } = await Runtime.evaluate({ expression: expr, returnByValue: true })
console.log(JSON.stringify(result.value, null, 2))
await client.close()
```

The `extractProfile` function is **the same code** that becomes the Safari
content-script parser (Part 3) — develop it here, paste it there.

### 2c. What the agent CAN do autonomously

- Write the parser + the selftest harness.
- Run unit tests over **saved HTML fixtures** (a logged-in profile's saved
  `Cmd-S` HTML committed under `Tests/fixtures/linkedin/` — scrubbed of PII or
  using the user's own profile by consent). This gives the agent a real,
  CI-friendly regression test for the brittle selectors **without** needing a
  live login. Strongly recommended: it's the only durable guard against
  LinkedIn markup drift.
- Iterate selectors against fixtures; hand the user the live-Chrome harness for
  final validation against the real DOM.

### 2d. Reality check on brittleness

LinkedIn rotates class names and lazy-loads sections, and (confirmed from the
saved profile) the logged-in page has **no JSON-LD and no OpenGraph meta tags**
to fall back on. The parser must be **best-effort with graceful failure** (return
`null` per field, never throw), anchor only on **stable semantic signals**
(`<title>`, `aria-*`, `alt` text, section landmarks, visible-text proximity) —
**never** the generated class names — and degrade to "couldn't read this page"
rather than guessing. Expect ongoing selector maintenance: this is the feature's
main long-term cost, and the committed fixture is what catches the breakage.

---

## Part 3 — Parsing: Name, Photo, Job title, Current organization, Bio, Location, Contact info

### Target fields (v1)

1. **Name** — full name → split into given/family (best-effort; last token =
   family, rest = given; keep raw full name too). Sourced from `<title>` and/or
   the photo `alt`, cross-checked against the top-card `<h2>`.
2. **Photo** — the profile image. **Fetch the bytes inside the content script**
   (in-session) from the smallest adequate `srcset` variant; pass bytes (or an
   App Group handle) to native, **not** just a URL.
3. **Job title** — current headline/title (top-card headline line).
4. **Current organization** — current company (from the headline's "… at <Org>"
   or the top experience entry).
5. **Bio** — the "About" section free text → sidecar `ContactNote`.
6. **City/State/Location** — the verbatim locality string under the name
   (e.g. `Tomball, Texas, United States`).
7. **Contact info (emails / webpages / profile URL)** — behind the **"Contact
   info" button** → opens an overlay/modal. Requires a click-then-wait-then-parse
   interaction (see below). Emails → `Contact.emailAddresses`; webpages →
   `Contact.urlAddresses`; the canonical profile URL → `LabeledSocialProfile`.

### Parser contract

Anchors are derived from the saved profile (2026-06-26). They use **semantic
signals, never rotating classes.** Treat the specific selectors as a starting
point to validate against the live DOM in Part 2; the *contract* (field names,
null-on-failure, anchor strategy) is the stable part.

```js
function extractProfile() {
  const text = (el) => el ? el.textContent.trim() : null
  const q = (sel) => document.querySelector(sel)
  const safe = (fn) => { try { return fn() } catch { return null } } // one field failing never breaks others

  // Photo: anchor on the alt text, NOT on classes. In the live DOM src is a
  // media.licdn.com URL; srcset carries multiple sizes — pick a small one.
  const photoImg = q('img[alt^="View "][alt*="profile"]')

  // Name: <title> "Name | LinkedIn" is the most stable; cross-check the alt.
  const fromTitle = safe(() => document.title.replace(/\s*\|\s*LinkedIn\s*$/, '').trim())
  const fromAlt   = safe(() => photoImg && photoImg.alt.replace(/^View\s+/, '').replace(/[’']s profile$/, '').trim())

  return {
    sourceUrl: location.href,
    fullName:  fromTitle || fromAlt,
    headline:  safe(() => /* top-card headline line — finalize vs live DOM */ null),
    title:     safe(() => /* parsed from headline or top experience entry */ null),
    org:       safe(() => /* parsed from headline "… at <Org>" or top experience */ null),
    location:  safe(() => /* verbatim locality text node in top card */ null),
    about:     safe(() => /* "About" <section> body text */ null),
    photoSrcset: safe(() => photoImg && (photoImg.getAttribute('srcset') || photoImg.currentSrc || photoImg.src)),
    parsedAt:  new Date().toISOString(),  // NOTE: replace with a host-passed timestamp in tests; new Date() is fine in the live content script
  }
}
```

**Photo bytes (content script, in-session):** after picking a small `srcset`
variant URL, fetch it from within the page so cookies/session apply, then hand
bytes to native:

```js
async function fetchPhotoBytes(url) {
  const res = await fetch(url, { credentials: 'include' })   // in-session; avoids the licdn out-of-browser block
  const blob = await res.blob()
  return await new Promise((ok) => {
    const r = new FileReader(); r.onload = () => ok(r.result); r.readAsDataURL(blob) // data: URL; or transfer ArrayBuffer
  })
}
```

**Contact info modal (click-then-parse):** the emails / webpages / canonical
profile URL live behind a **"Contact info"** button that opens an overlay. This
is an *interaction*, not a static read, so it needs care:

```js
async function extractContactInfo() {
  // Anchor the trigger on its accessible text, not a class:
  const trigger = [...document.querySelectorAll('a,button')]
    .find(el => /contact info/i.test(el.textContent || el.getAttribute('aria-label') || ''))
  if (!trigger) return null
  trigger.click()
  // Wait for the dialog to appear (poll for role="dialog"); bounded retries, never hang:
  const dialog = await waitFor(() => document.querySelector('[role="dialog"]'), { tries: 20, intervalMs: 100 })
  if (!dialog) return null
  const info = {
    profileUrl: safe(() => dialog.querySelector('a[href*="/in/"]')?.href),
    emails:     [...dialog.querySelectorAll('a[href^="mailto:"]')].map(a => a.href.replace(/^mailto:/, '')),
    websites:   [...dialog.querySelectorAll('a[href^="http"]')].map(a => a.href)
                  .filter(h => !/linkedin\.com/.test(h)),
  }
  // Close the dialog to leave the page as we found it (Esc or the close button):
  (dialog.querySelector('[aria-label*="Dismiss" i],[aria-label*="Close" i]') || document.body)
    .dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true }))
  return info
}
```

> Caveats for the modal step, to design for: (1) it mutates the page (opens a
> dialog) — only do it on explicit user action, and **restore state** by closing
> it; (2) it's async with arbitrary load time — poll with a bounded retry, never
> block; (3) the exact selectors inside the dialog must be confirmed against the
> live DOM in Part 2 (the saved snapshot may not have the modal expanded);
> (4) some profiles hide Contact info or expose only a subset.

### Field → write mapping (native side)

- `title`  → `editable.jobTitle`
- `org`    → `editable.organizationName`
- `about`  → `repo.addNote(for:body:)` (sidecar note, **not** a CNContact field)
- `location` → **sidecar free-text field** (decided: verbatim, no parsing)
- `fullName` → used for **matching**; offered as an editable diff row but
  defaults to *not* overwriting an existing name
- `photo bytes` → **new contact-image write path** (net-new package work, in v1):
  a new package API (`setImageData(_:for:)`-shaped) whose *signature* mirrors the
  read side, but whose implementation needs a dedicated fetch-with-image-keys +
  separate image-including save (see "Real gaps" #1 — `saveContact`/`apply()`
  skip image data). Shown in the diff as before/after thumbnails.
- `emails`   → merged into `editable.emailAddresses` (dedupe; label "LinkedIn")
- `websites` → merged into `editable.urlAddresses` (dedupe; label "LinkedIn")
- `sourceUrl` / `profileUrl` → ensure a `LabeledSocialProfile` (service
  "LinkedIn") exists

### Match → diff → save flow (in the **app process**, via `ContactsRepository`)

1. App receives the handed-off payload (text + photo bytes + contact info).
2. **Match.** **Heads-up (post-review): there is NO social-profile / URL lookup
   primitive today.** `ContactsRepository` exposes `contactIDs(named:)`,
   `contactIDs(matchingEmail:)`, and `lookupByDisplayName()` — but **no**
   `contactIDs(matchingSocialProfileURL:)`. So either:
   - **(a)** match on **name** (`contactIDs(named: fullName)` /
     `lookupByDisplayName()`) and, if Contact info was parsed, **email**
     (`contactIDs(matchingEmail:)`) — both exist today; **or**
   - **(b)** add a small **net-new** `contactIDs(matchingSocialProfileURL:)`
     primitive (preferred for precision, since a LinkedIn URL is a near-unique
     key, but it is new package work — don't assume it exists).
   v1 recommendation: ship with (a) name+email matching; add (b) if name
   collisions prove noisy. **v1 is enrich-existing-only:** zero matches → show
   the parsed preview but **no save** (create-new is phase 2); multiple →
   user picks in the UI.
3. **Diff:** load `editableContact(id:)`, build a per-field before/after list
   (old value, new value, changed?) covering title, org, location (sidecar),
   about (sidecar note), emails, websites, social profile, and the **photo**
   (before/after thumbnails).
4. Return diff to popup; popup renders before/after with per-field
   include/exclude toggles.
5. **Save:** popup → native → apply included fields → `saveContact(_:for:)`,
   `addNote(...)`, and the new contact-image write API as needed. **Discard:**
   popup just closes; nothing written.

This save/discard + per-field confirm keeps the user in control and matches how
GuessWho already treats enrichment (and the sidecar-is-invisible product
principle: the user sees "contact / notes / job title", never "sidecar").

---

## Final phase — previous-photo preservation + `.blob` sidecar field type

This is the **last phase** of the project (per user, 2026-06-26), built after the
LinkedIn enrichment flow ships. It has two parts: a new sidecar field type, and
the read-before-write snapshot that uses it.

### `.blob` sidecar field type (net-new package work)

**Design (decided 2026-06-26): a `.blob` field stores a *pointer* to a separate
synced binary file that lives beside the envelope JSON — NOT inline base64.**
This keeps the synced envelope JSON small and makes full-res photos viable.

**Correction (post-review): the bytes do NOT sync "for free."** Two things the
earlier draft got wrong, both verified against the code:
- **The `.dat` must live under the iCloud ubiquity container**, same root as the
  `.json` (`root/contacts/...`), or it won't sync at all. (An App-Group `.dat`
  would not sync — see the Architecture correction.)
- **The store's enumeration/placeholder layer is `.json`-only.** `listKeys()`
  matches `pathExtension == "json"` (`FileSystemSidecarStore.swift:370`),
  `realNameFromPlaceholder()` requires a `.json` suffix (`:407`), and
  `allKeys()` (used by the orphan sweep, `GuessWhoSync.swift:457`) is therefore
  `.json`-only. So a `.dat` is **invisible** to key listing and placeholder
  handling today. The **URL-based** ubiquity provider methods (coordinated
  read/write/download for a specific file URL) **do** compose for a `.dat`, but
  the **filename-pattern enumeration layer does not** — `.dat` listing,
  `.icloud`-placeholder handling for `.dat`, and orphan detection are all
  **net-new work**, not inherited.

#### How it fits the existing store layout

`FileSystemSidecarStore` already lays out **one file per key** under a per-kind
directory and syncs each file independently via `SidecarUbiquityProvider` +
`NSFileCoordinator` (verified 2026-06-26):

- `root/contacts/<id>.json`, `root/events/<id>.json`, `root/links/<id>.json`.
- Not-yet-downloaded files appear as `.<name>.json.icloud` placeholders;
  `read()` already distinguishes materialized / placeholder / missing and can
  trigger download.

A blob is **another file in the same per-kind directory**, e.g.:

```
root/contacts/<contactid>.json            ← envelope (small; holds the pointer)
root/contacts/<contactid>.<blobid>.dat    ← binary payload (e.g. previous photo)
```

The `.blob` field's **value is the pointer** (the `<blobid>` + minimal metadata:
content-type, byte length, maybe a checksum), not the bytes. The `.dat` lives
under the **same iCloud ubiquity root** as the `.json` so it syncs — but the
store's `.json`-only enumeration must be **extended** to see/coordinate `.dat`
files (it does not today; see the correction above).

#### Package surface to touch (all in `Sources/GuessWhoSync/`)

- **`SidecarFieldType.swift`** — add `case blob` (payload = a small JSON object
  describing the pointer, e.g. `{ "blobId", "contentType", "byteCount" }`),
  following the comment convention used for `.note`/`.date`.
- **`JSONValue` needs no new case** — the pointer object is a plain
  `.object([...])`. No raw bytes ever enter `JSONValue`, so the envelope
  encoder/decoder is untouched.
- **Blob file I/O on the store** — net-new methods on `SidecarStoreProtocol` /
  `FileSystemSidecarStore` to write/read/delete a blob file for a key
  (`writeBlob(_:for:id:)`, `readBlob(for:id:)`, `deleteBlob(for:id:)`). Reuse the
  **URL-based** coordinated-read / busy-handler / ubiquity machinery (those
  compose), but **add `.dat` handling to the enumeration/placeholder layer** —
  model the not-yet-downloaded `.dat` on how `read()` surfaces "exists remotely,
  not materialized" so it isn't a spurious miss. `InMemorySidecarStore` (in the
  **`GuessWhoSyncTesting`** target, not `GuessWhoSync`) gets a matching in-memory
  blob map.
- **`SidecarField.validate(value:against:)`** — `.blob` arm: require the pointer
  object shape (string `blobId`, etc.), reject malformed with `typeValueMismatch`
  (mirrors how `.date` requires ISO8601).
- **`SidecarField.decode` / `makeInnerValue` / `makeInnerValueForEdit`** — audit
  for `.note`/`.date`/`.checkbox`-only assumptions; extend for the pointer object.
- **`blobId` minting** — mint a **fresh UUID per write** (never reuse/derive
  from contact id), so a new snapshot never collides with an in-flight older
  `.dat` mid-sync. Specify this explicitly; the earlier draft left it undefined.
- **Lifecycle / orphans — bigger than "delete on overwrite" (post-review M3).**
  The envelope merge is **whole-cell last-writer-wins** (`SidecarMerge.swift:26`:
  "Whole-cell LWW," winner by `modifiedAt` then `modifiedBy`). So in a routine
  cross-device race — two devices each snapshot a *different* previous photo —
  the merge keeps **one** cell and **silently drops the loser's pointer**, but
  the **loser's `.dat` survives on disk unreferenced**. This is a normal path,
  not an edge case. Mitigation: a **reference-counting orphan sweep** — a `.dat`
  is deletable only when **no** envelope (across all keys, post-merge) points at
  its `blobId`. Single-slot delete-on-overwrite is necessary but **not
  sufficient**; the sweep is required. Conflict-reconcile
  (`@_spi(ConflictReconcile)`) and merge must not drop a still-referenced blob or
  resurrect a dereferenced one — test the cross-device snapshot race explicitly.
- **Tests** — `SidecarFieldTests` (+ field-type round-trip) for `.blob`
  encode/decode + validation reject; new store tests for blob write/read/delete,
  the `.icloud` placeholder path for a `.dat`, and orphan cleanup on overwrite
  and on envelope delete.

#### Trade-off vs. inline base64

A pointer-file means **two files can be momentarily out of step** during sync
(envelope arrives before its `.dat`, or vice-versa). Handle it the way `read()`
already handles a missing/placeholder file: treat a referenced-but-not-yet-
materialized blob as "pending download," not "gone," and don't delete a pointer
just because its `.dat` hasn't landed yet. This is the one real complexity the
file approach adds — and it's exactly the complexity the store is already built
to handle for envelopes.

### Previous-photo snapshot (uses `.blob`)

A **general rule** in the contact-image **write path** — every caller that
replaces a photo gets this for free, not just the LinkedIn flow:

1. Before overwriting a contact's `CNContact` image, **read the current photo
   bytes** via the existing read path (`plans/contact-profile-photos.md`).
   Because the blob is now a synced **file** (not inline JSON), storing the
   **full-size** previous photo is viable — no envelope bloat. (Pick full-size
   vs. thumbnail during implementation; full-size is the better default now.)
2. If a current photo exists, **write those bytes via the store's blob API**
   (creates `root/contacts/<id>.<blobid>.dat`) and set the contact's
   `previousPhoto` `.blob` field to point at it. No current photo → nothing to
   snapshot.
3. **Keep a single previous-photo slot** for v1 — overwriting deletes the prior
   `.dat` (orphan cleanup above). A history of N is a later option if wanted.
4. Then perform the actual image write.

Surfacing it (revert / history UI) is **not built here** — this phase only
guarantees the previous photo is **captured** and retrievable. When it is
surfaced, it's user-safe to call **"previous photo"** (plain language; does not
leak sidecar vocabulary, per the product principle).

---

## iOS portability (kept cheap, not built in v1)

Author v1 so iOS is a later **add-a-target**, not a rewrite:

- **Non-persistent background page** (iOS requires it; works on macOS too) —
  write the background script event-driven from day one.
- **Popup sized for a phone sheet**, not just a desktop popover.
- Keep **all** parsing/matching logic in the shared web-ext folder +
  `GuessWhoSync`; nothing macOS-specific in the JS.
- Share the same extension folder between a future iOS app target and the
  macOS one in the same `GuessWho.xcodeproj`.

Defer the iOS enablement-flow onboarding copy (Settings → Apps → Safari →
Extensions + per-site allow) until we actually add the target.

## Decisions made (2026-06-26)

- **Photo: in v1.** Build the net-new contact-image write path (a
  fetch-with-image-keys + separate image-including save; `saveContact` skips
  image data). Photo **bytes** are fetched **inside the content script**
  (in-session) because the `media.licdn.com` URL may reject out-of-browser
  fetches like the profile page does — **this requires `licdn.com` in
  `host_permissions`** or the in-session `fetch()` is CORS-blocked. Pick a small
  `srcset` variant; park bytes in the **App Group** (ephemeral handoff) for the
  app to pick up. Decided over deferring to a fast-follow.
- **Architecture (post-review): extension does parsing/transport only; the APP
  process does match/diff/save.** The synced sidecar lives in the **iCloud
  ubiquity container** (not an App Group); only the app holds the iCloud +
  Contacts entitlements. App Group = ephemeral IPC handoff only. The
  extension→app wake mechanism is the top Part-1 spike question.
- **Identity / App Group (verified vs. Apple docs):** extension bundle id =
  **`com.milestonemade.guesswho.safari`** (app id + `.safari`). App Group =
  a single **`group.com.milestonemade.guesswho`** shared by app + extension on
  both iOS and Mac Catalyst — `group.`-prefixed is the cross-platform format and
  Catalyst uses it (the `<TeamID>.` form is a macOS-only *alternative* that skips
  registration, irrelevant here). **No App Group exists in the repo today** —
  entitlements declare only iCloud (`iCloud.com.milestonemade.guesswho`). See
  "1b. Identity, entitlements & App Group."
- **Location: verbatim sidecar string**, no `PostalAddress` parsing.
- **Contact info:** **in scope** — click the "Contact info" button and parse the
  modal for emails / webpages / canonical profile URL. Treated as a careful
  click-then-parse interaction that restores page state afterward.
- **Fixtures by consent: yes.** Commit a **minimal** scrubbed slice of the
  user's own profile under `Tests/fixtures/linkedin/` — "save as little as
  possible for it to be useful." The raw 3.2 MB `Cmd-S` save in
  `~/Downloads/linkedin/` is the *source*; we extract only the top-card +
  About + (if present) Contact-info DOM fragments needed to exercise the parser,
  and strip large inlined data blobs and third-party assets. **Do not** commit
  the full 3.2 MB HTML or the 24 MB `_files` folder.

## Open questions still needing your input

1. ~~Bundle id / App Group naming~~ **RESOLVED (2026-06-26):** extension id
   `com.milestonemade.guesswho.safari`; App Group
   `group.com.milestonemade.guesswho` (single id, iOS + Catalyst); no group
   exists yet — net-new entitlement. See "1b. Identity, entitlements & App
   Group." Remaining sub-task is just to create + register it in Xcode.
2. **"Match-only" UX when there are 0 matches** — in v1 (enrich-existing-only),
   what should the popup show when the LinkedIn person isn't in the DB yet?
   (Suggest: a clear "no matching contact found" with the parsed preview, but no
   save — creation lands in phase 2.)

## Suggested build order

### Progress (2026-06-26)

Steps 0–2 ✅ done. Step 4 (match + diff + save) ✅ done **except the photo**.
Step 3 (the contact-image **write path**) ⏳ is the ONE remaining v1 item — the
`.photo` field flows all the way to the app but applying it is still a no-op.
Detailed app-side status: `plans/linkedin-match-diff-confirm.md`.

### v1 (this feature)

0. ✅ **Architecture spike (do FIRST, post-review)** — prove the
   **extension → app handoff**: content/background → `sendNativeMessage` →
   `SafariWebExtensionHandler` (extension process) → park a payload in the App
   Group → **wake the app** → app reads it. Settle the wake mechanism (URL
   scheme / universal link vs. App Group observation). This de-risks the single
   biggest unknown before any feature work. Confirm the App Group entitlement on
   both targets and that the **app** (not extension) holds the iCloud/Contacts
   entitlements.
1. ✅ **Extension target + pipe** — Safari Web Extension target added, handoff
   proven on Catalyst.
2. ✅ **Parser** — `extractProfile` parses name/headline/title/org/location/about
   (newline-preserving) + Contact-info modal + in-session photo-bytes fetch.
3. ⏳ **Contact-image write path** — net-new `GuessWhoSync` API: dedicated
   fetch-with-image-keys + separate image-including save request (NOT a tweak to
   `saveContact`, which deliberately skips image data). **NOT YET BUILT** — the
   one remaining v1 item.
4. ✅ **Match + diff + save (app process)** — `matchLinkedIn` (URL → email →
   name), `LinkedInConfirmView` per-field checkbox diff, `applyLinkedIn`
   merge-save. **Enrich-existing-only.** Photo row exists in the diff but its
   save is a no-op pending step 3.

### Phase 2 (follow-on, explicitly deferred)

5. **Create-new-contact from a LinkedIn profile** — when there's no match, allow
   minting a brand-new GuessWho contact from the parsed profile (consistent with
   "Add contact always creates new"). Moved out of v1 per user. Until then, the
   0-match case is preview-only (no save).
6. **iOS target** — add second app target sharing the same extension folder.

### Final phase

7. **Previous-photo preservation + `.blob` sidecar type** — add `case blob` to
   `SidecarFieldType` as a **pointer to a synced binary file** beside the
   envelope (`root/contacts/<id>.<blobid>.dat`, under the iCloud root). Scope is
   larger than first stated (post-review): **extend the `.json`-only
   enumeration/placeholder layer to handle `.dat`**, mint a **fresh UUID per
   write**, and add a **reference-counting orphan sweep** (whole-cell LWW merge
   routinely orphans a loser's `.dat`). Then make the contact-image write path
   snapshot the old photo into a `previousPhoto` `.blob` before overwriting.
   General rule across all photo changes, not just LinkedIn. Built last, per user.

## References (verified 2026-06-26)

- Messaging between the app and JS in a Safari web extension —
  <https://developer.apple.com/documentation/safariservices/messaging-between-the-app-and-javascript-in-a-safari-web-extension>
- Safari Web Extensions (overview / shared codebase across platforms) —
  <https://developer.apple.com/documentation/safariservices/safari-web-extensions>
- What's new in Safari extensions (WWDC23) —
  <https://developer.apple.com/videos/play/wwdc2023/10119/>
- Build and deploy Safari Extensions for iOS (Tech Talks) —
  <https://developer.apple.com/videos/play/tech-talks/110148/>
- **App Groups Entitlement** (format rules: `group.<name>` cross-platform incl.
  Catalyst; `<TeamID>.<name>` is a macOS-only unregistered alternative) —
  <https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.application-groups>
- **Configuring app groups** (Xcode capability flow; "a container ID must begin
  with `group.`"; registration needed for iOS/iPadOS/tvOS/visionOS/watchOS) —
  <https://developer.apple.com/documentation/xcode/configuring-app-groups>
- Repo identity facts (verified 2026-06-26): app id `com.milestonemade.guesswho`,
  team `T68Z94627S`, entitlements `App/GuessWho/GuessWho.entitlements` (iOS) +
  `GuessWho-MacCatalyst.entitlements` (macosx) — iCloud-only, **no App Group yet**.
- Existing GuessWho machinery: `Sources/GuessWhoSync/Contact.swift`,
  `ContactsRepository.swift`, `SocialProfile.swift`, `ContactNote.swift`,
  `plans/contact-profile-photos.md`.
