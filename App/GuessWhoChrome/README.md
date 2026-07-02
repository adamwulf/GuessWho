# GuessWho LinkedIn — Chrome / Brave extension

The Chromium port of the LinkedIn Safari Web Extension
(`App/GuessWhoLinkedIn`). Same job: parse the LinkedIn profile the user is
viewing and hand it to the GuessWho app, which shows a before/after diff the
user confirms before anything is saved.

**This directory is not a second copy of the extension.** The parser
(`parse-profile.js`), content script, popup, and icons are copied **verbatim**
from `../GuessWhoLinkedIn/Resources/` by `build.sh` at build time — one source
of truth for everything LinkedIn-DOM-shaped. Only three things are
Chrome-specific:

| File | Why it exists |
| --- | --- |
| `Sources/manifest.template.json` | Chrome manifest: adds the `key` (stable extension ID) and the `http://127.0.0.1/*` host permission; drops Safari's unused `nativeMessaging`/`storage` permissions. |
| `Sources/background.js` | The transport. Chromium has no containing-app native handler, so instead of `sendNativeMessage` → App Group parking, it opens the wake URL and POSTs the payload to the app's localhost listener. |
| `config.js` (generated) | Per-flavor wiring (port, wake scheme), parsed out of the xcconfigs by `build.sh`. |

## How the handoff works (vs. Safari)

```
Safari:  popup → background → sendNativeMessage → handler parks file in App Group
         popup opens guesswho-linkedin[-debug]://handoff → app drains the file

Chrome:  popup → background ─┬─ 1) navigates the active tab to the same wake URL
                             │     (launches/foregrounds the app; Brave asks
                             │     "Open GuessWho?" once — tick "Always allow")
                             └─ 2) POST http://127.0.0.1:<port>/handoff
                                   (retries ~60 s while the app cold-launches)
```

App side, both transports converge on
`GuessWhoSceneDelegate.processLinkedInHandoff` — the same match → diff →
confirm → save pipeline. The listener (`App/GuessWho/LinkedInLocalhostReceiver.swift`,
started by `GuessWhoAppDelegate`, **Mac Catalyst only**) binds 127.0.0.1 only,
rejects bodies over 8 MB, and only accepts POSTs whose `Origin` is an allowed
`chrome-extension://<id>` (the allowlist is `GUESSWHO_CHROME_EXTENSION_IDS` in
`App/Config/GuessWho-<Config>.xcconfig`).

Nothing here weakens the sidecar rules: the extension holds no GuessWho data;
the payload is ephemeral and user-confirmed in the app before any write.

## Flavors, ports, and IDs

`build.sh` parses the xcconfigs (never duplicate these values here):

| | Debug | Release |
| --- | --- | --- |
| App listener port | `57231` | `57230` |
| Wake scheme | `guesswho-linkedin-debug` | `guesswho-linkedin` |
| Extension name | GuessWho LinkedIn Debug | GuessWho LinkedIn |
| Pinned dev extension ID | `alnaedlcjmeghdgbejppfmjgmhhoaami` | `hckkbhkjpmolhnihnjeglnlkdknbeaha` |

A **Debug-flavor extension can only ever talk to the Debug app** (different
port, different wake scheme), mirroring the repo-wide Debug/Release identifier
convention.

The IDs are stable because each manifest pins a `key` (`keys/*.pub` — public
keys only; there is no private key to protect since we never sign a `.crx`).
Chrome derives the ID from that key, so load-unpacked yields the same ID on
every machine — which is what lets the app pin its Origin allowlist. `build.sh`
prints the expected ID per flavor; it must match what `brave://extensions`
shows after loading.

## Build

```sh
cd App/GuessWhoChrome
./build.sh            # debug flavor → dist/debug/
./build.sh release    # release flavor → dist/release/
./build.sh store      # store package → dist/store/ + build/GuessWhoChrome-<version>.zip
./build.sh all        # all three
```

Output is disposable (`dist/`, `build/` are gitignored); the inputs are the
Safari `Resources/`, `Sources/`, `keys/`, and the xcconfigs.

## Test locally (unpacked, developer mode in Brave)

Chrome works identically — substitute `chrome://` for `brave://`.

1. Build the **Debug app** once and leave it installed (it registers the
   `guesswho-linkedin-debug` scheme with LaunchServices and owns port 57231):

   ```sh
   xcodebuild -project App/GuessWho.xcodeproj -scheme GuessWho \
     -destination 'platform=macOS,variant=Mac Catalyst' \
     -derivedDataPath .build/DerivedData build
   ```

2. `./build.sh` (debug is the default flavor).
3. In Brave: `brave://extensions` → enable **Developer mode** (top right) →
   **Load unpacked** → pick `App/GuessWhoChrome/dist/debug/`.
4. Check the extension ID shown on the card is
   `alnaedlcjmeghdgbejppfmjgmhhoaami` (else the app will 403 the POST — see
   Troubleshooting).
5. Open a `https://www.linkedin.com/in/<someone>` profile, click the GuessWho
   toolbar button. The popup streams "Loading profile… N/4 sections" while the
   page scrolls in; **Save anyway** interrupts the wait and ships what parsed.
6. First run only: Brave shows *"Open GuessWho Debug?"* — tick **Always
   allow** and confirm. The app foregrounds and presents the confirm sheet.

Iterating: after editing extension JS (in `../GuessWhoLinkedIn/Resources/` for
shared files, `Sources/` for Chrome ones), re-run `./build.sh`, then hit the
**Reload** (⟳) button on the extension card in `brave://extensions`. Unpacked
extensions never auto-update.

### Debug consoles

- **Popup / content script:** right-click the popup → Inspect; the LinkedIn
  tab's DevTools console shows `[GuessWho]` parser lines.
- **Background worker:** `brave://extensions` → the extension card →
  **service worker** link. Look for `[GuessWho][bg]` lines — the wake and the
  POST retry loop log there.
- **App side:** `<AppGroup>/Logs/app.log` (Help → Open Container Folder),
  categories `app.linkedin-handoff` and `app.linkedin-handoff.chrome`. A
  healthy handoff logs `listening on 127.0.0.1:57231` at launch, then
  `handoff received: <N>B from chrome-extension://…`, then the shared
  `processing handoff payload` → `match:` → `diff:` lines.

## Pack + upload to the Chrome Web Store

One-time setup: register as a CWS developer at
<https://chrome.google.com/webstore/devconsole> ($5 one-time fee, any Google
account).

1. ```sh
   ./build.sh store
   ```
   This produces `build/GuessWhoChrome-<version>.zip` — the Release wiring
   (port 57230, `guesswho-linkedin` scheme) with **no `key` in the manifest**:
   the Web Store manages the published key and **assigns its own extension
   ID**; uploads containing a `key` are rejected.
2. In the [developer dashboard](https://chrome.google.com/webstore/devconsole):
   **Add new item** → upload the zip.
3. Fill the listing (store icon = `icon-128.png`, at least one 1280×800
   screenshot, description, category *Productivity*) and the **Privacy**
   tab — single purpose ("save the LinkedIn profile you're viewing into the
   GuessWho app"), permission justifications (`activeTab`/`scripting`: parse
   the profile tab on click; `linkedin.com`/`licdn.com`: read the profile DOM
   and fetch the profile photo; `127.0.0.1`: hand the parsed profile to the
   GuessWho app running on this Mac). No remote code, no data leaves the
   machine — say so; it's true and reviewers care.
4. Under **Distribution**, set visibility:
   - **Unlisted** — recommended. No searchable store page; anyone with the
     direct link can install. This is what lets the app offer an
     "Install for Chrome/Brave" button that deep-links to the URL.
   - Public/Private work the same mechanically; Private limits to trusted
     testers.
5. Submit for review (typically a few days for a first submission).
6. **After the upload, copy the store-assigned item ID** (32 a–p letters, in
   the dashboard URL and the item page) and append it to
   `GUESSWHO_CHROME_EXTENSION_IDS` in `App/Config/GuessWho-Release.xcconfig`
   (comma-separated, after `hckkbhkjpmolhnihnjeglnlkdknbeaha`), then rebuild
   the app. Until then the Release app only admits the dev-key ID and will
   403 the store-installed extension.

Updates: bump `MARKETING_VERSION` in `App/Config/SharedVersion.xcconfig` (the
manifest version comes from there), `./build.sh store`, upload the new zip on
the item's **Package** tab. Store installs auto-update; the item ID never
changes, so the app allowlist doesn't either.

Brave users install from the same Chrome Web Store link — Brave has no
separate store.

## Troubleshooting

- **`Failed to fetch` in the service-worker console, app never shows the
  sheet** — the listener isn't up: the app isn't running/installed, or a
  flavor mismatch (Debug extension ↔ Release app talk different ports on
  purpose). Check `app.log` for `listening on 127.0.0.1:<port>`.
- **HTTP 403 in the service-worker console** — Origin not in the allowlist.
  Compare the ID in `brave://extensions` with `GUESSWHO_CHROME_EXTENSION_IDS`
  in the matching `GuessWho-<Config>.xcconfig`; `app.log` logs the rejected
  origin verbatim.
- **`listener failed … Chrome handoff unavailable` in app.log** — the port is
  already bound, usually a second running copy of the app (e.g. a worktree
  build). Quit the other copy.
- **No "Open GuessWho?" dialog and the app doesn't foreground** — the wake
  navigation was swallowed; the payload still lands if the app is running.
  Check the `[GuessWho][bg]` `wake:` lines for the fallback path.
- **App opens but logs `read: no pending-handoff.json … nothing parked`** —
  normal for the Chrome flow (that's the Safari parked-file drain); the
  payload arrives via `app.linkedin-handoff.chrome` moments later.
