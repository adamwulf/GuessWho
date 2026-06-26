# Plan: LinkedIn enrichment via Safari Web Extension (macOS first)

## Status (2026-06-26)

Planning only. No app, package, or Xcode-project changes have been made.

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
   contact-profile-photos plan (`plans/contact-profile-photos.md`) deliberately
   covers **loading** image bytes only (`contactPhotoData(for:kind:)`); there is
   no `setImageData(...)` / write API, and `CNContactStoreAdapter.keys` omits the
   image-data keys from bulk fetches. Writing a LinkedIn photo into the
   underlying `CNContact` is **net-new package work** and the largest single item
   in this feature. **Decision (2026-06-26): photo is in v1.** This means
   building the write path, not deferring it.
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

Three pieces, bundled into the GuessWho app, sharing an **App Group** with it:

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
[SafariWebExtensionHandler.swift]  (native, in-app process)
        │  GuessWhoSync: match by name/URL → build before/after diff
        ▼  returns diff
[popup HTML/JS]  render before/after → Save / Discard
        │  on Save → native handler → saveContact / addNote
        ▼
GuessWho sidecar + Contacts (via App Group / ContactsRepository)
```

Native ↔ JS messaging facts (Apple docs, verified 2026-06-26):

- JS → native: `browser.runtime.sendNativeMessage("<ext bundle id>", payload, cb)`.
- Native receives in `SafariWebExtensionHandler.beginRequest(with:)`, replies via
  `context.completeRequest(returningItems:)`.
- **The containing app need not be running** for messaging to work.
- Message size is bounded by `NSExtensionContext`. Text fields go inline. For
  the **photo**, the content script fetches the bytes in-session (see Photo
  write gap) — if the resulting payload is too large for the channel, write it
  to the shared App Group container and pass only a handle. Pick the smallest
  adequate `srcset` variant to keep payloads small.
- App Group + shared `UserDefaults(suiteName:)` (and the shared container for
  image bytes) is the durable shared-storage path between extension and app.

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

### 1b. Entitlements & App Group

- Create App Group `group.<team>.com.adamwulf.guesswho` (or match existing
  bundle-id convention in `App/Config/`).
- Add the App Group entitlement to **both** the GuessWho app target and the new
  extension target.
- Both targets signed with the same team ID.
- Add `App/Config/` entries if the project keeps entitlements/xcconfig there
  (confirm during implementation — `App/Config/` exists).

### 1c. Manifest host permissions (keep tight)

- `"host_permissions": ["*://*.linkedin.com/*"]` only.
- `"permissions": ["activeTab", "nativeMessaging", "storage"]`.
- Narrow scope = smaller user consent prompt and easier review.

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
  write to the unified `CNContact` image data via a new package API
  (`setImageData(_:for:)`-shaped), mirroring the read side in
  `plans/contact-profile-photos.md`. Shown in the diff as before/after thumbnails.
- `emails`   → merged into `editable.emailAddresses` (dedupe; label "LinkedIn")
- `websites` → merged into `editable.urlAddresses` (dedupe; label "LinkedIn")
- `sourceUrl` / `profileUrl` → ensure a `LabeledSocialProfile` (service
  "LinkedIn") exists

### Match → diff → save flow (native, in `GuessWhoSync`)

1. Native handler receives parsed payload (text + photo bytes + contact info).
2. **Match:** try existing LinkedIn `socialProfiles` URL first; else
   `contactIDs(named: fullName)` / `lookupByDisplayName()`. **v1 is
   enrich-existing-only:** zero matches → popup shows the parsed preview but
   **no save** (create-new is phase 2); multiple → let user pick in the popup.
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
This is better than inlining: it keeps the synced envelope JSON small, and the
bytes get the **same per-file iCloud sync** the store already implements for
`.json` files (placeholder/download coordination, conflict handling) **for
free**. It also makes full-res photos viable later without a redesign.

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
content-type, byte length, maybe a checksum), not the bytes. iCloud syncs the
`.dat` exactly like the `.json`, including the `.icloud` placeholder dance.

#### Package surface to touch (all in `Sources/GuessWhoSync/`)

- **`SidecarFieldType.swift`** — add `case blob` (payload = a small JSON object
  describing the pointer, e.g. `{ "blobId", "contentType", "byteCount" }`),
  following the comment convention used for `.note`/`.date`.
- **`JSONValue` needs no new case** — the pointer object is a plain
  `.object([...])`. No raw bytes ever enter `JSONValue`, so the envelope
  encoder/decoder is untouched.
- **Blob file I/O on the store** — net-new methods on `SidecarStoreProtocol` /
  `FileSystemSidecarStore` to write/read/delete a blob file for a key
  (`writeBlob(_:for:id:)`, `readBlob(for:id:)`, `deleteBlob(for:id:)`). These
  reuse the existing coordinated-read / placeholder / busy-handler / ubiquity
  machinery — model them on `read()`/`write()` so a not-yet-downloaded `.dat`
  surfaces the same "exists remotely, not materialized" state instead of a
  spurious miss. `InMemorySidecarStore` gets a matching in-memory blob map.
- **`SidecarField.validate(value:against:)`** — `.blob` arm: require the pointer
  object shape (string `blobId`, etc.), reject malformed with `typeValueMismatch`
  (mirrors how `.date` requires ISO8601).
- **`SidecarField.decode` / `makeInnerValue` / `makeInnerValueForEdit`** — audit
  for `.note`/`.date`/`.checkbox`-only assumptions; extend for the pointer object.
- **Lifecycle / orphans** — when a `.blob` field is overwritten or its envelope
  is deleted/reconciled, the old `.dat` must be cleaned up. Decide the policy
  (delete-on-overwrite for a single-slot previous-photo; a sweep for orphans).
  Conflict-reconcile (`@_spi(ConflictReconcile)`) and the merge paths must not
  drop a live blob or resurrect a deleted one — add tests for this.
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

- **Photo: in v1.** Build the net-new contact-image write path. Photo **bytes**
  are fetched **inside the content script** (in-session) because the
  `media.licdn.com` URL may reject out-of-browser fetches like the profile page
  does; pick a small `srcset` variant; pass bytes (or an App Group handle) to
  native. Decided over deferring to a fast-follow.
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

1. **Bundle id / App Group naming** — confirm the convention in `App/Config/`
   so signing lines up. (Agent will read `App/Config/` and propose a value.)
2. **"Match-only" UX when there are 0 matches** — in v1 (enrich-existing-only),
   what should the popup show when the LinkedIn person isn't in the DB yet?
   (Suggest: a clear "no matching contact found" with the parsed preview, but no
   save — creation lands in phase 2.)

## Suggested build order

### v1 (this feature)

1. **Part 1 pipe** — extension target + native hello-world round-trip (proves
   the hardest infra). Stop and hand residual GUI steps to user if `.pbxproj`
   surgery gets risky.
2. **Parser + fixtures** — `extractProfile` (+ photo-bytes + Contact-info modal)
   developed against the minimal committed fixture, unit tested; live-Chrome
   harness handed to user for real-DOM validation.
3. **Contact-image write path** — net-new `GuessWhoSync` API to write image bytes
   to the unified `CNContact`, mirroring the read side. Needed before the diff
   can save a photo.
4. **Match + diff + save** — native `GuessWhoSync` match (by LinkedIn URL then
   name), build before/after for **all** v1 fields (text + photo + emails +
   websites), popup renders the diff with per-field toggles, save/discard.
   **Enrich-existing-only** in v1.

### Phase 2 (follow-on, explicitly deferred)

5. **Create-new-contact from a LinkedIn profile** — when there's no match, allow
   minting a brand-new GuessWho contact from the parsed profile (consistent with
   "Add contact always creates new"). Moved out of v1 per user. Until then, the
   0-match case is preview-only (no save).
6. **iOS target** — add second app target sharing the same extension folder.

### Final phase

7. **Previous-photo preservation + `.blob` sidecar type** — add `case blob` to
   `SidecarFieldType` as a **pointer to a synced binary file** beside the
   envelope (`root/contacts/<id>.<blobid>.dat`), with store blob-I/O methods and
   orphan cleanup; then make the contact-image write path snapshot the old photo
   into a `previousPhoto` `.blob` before overwriting. General rule across all
   photo changes, not just LinkedIn. See "Final phase" above. Built last, per user.

## References (verified 2026-06-26)

- Messaging between the app and JS in a Safari web extension —
  <https://developer.apple.com/documentation/safariservices/messaging-between-the-app-and-javascript-in-a-safari-web-extension>
- Safari Web Extensions (overview / shared codebase across platforms) —
  <https://developer.apple.com/documentation/safariservices/safari-web-extensions>
- What's new in Safari extensions (WWDC23) —
  <https://developer.apple.com/videos/play/wwdc2023/10119/>
- Build and deploy Safari Extensions for iOS (Tech Talks) —
  <https://developer.apple.com/videos/play/tech-talks/110148/>
- Existing GuessWho machinery: `Sources/GuessWhoSync/Contact.swift`,
  `ContactsRepository.swift`, `SocialProfile.swift`, `ContactNote.swift`,
  `plans/contact-profile-photos.md`.
