# CLI install button — the `privileged-file-operations` entitlement is REQUIRED

**Author:** manager agent `install-button` · **Date:** 2026-08-14 ·
**Status:** findings + fix plan. No production code changed yet. This doc
**reopens and corrects** the "symlink entitlement — CLOSED, not needed"
conclusion in [`plans/cli-mcp.md`](cli-mcp.md) (lines 17, 95, 101) and in
[`plans/phase0-human-checklist.md`](phase0-human-checklist.md) (§5, lines
88–92). Those two statements are WRONG.

All `file:line` anchors were read at commit `c1ec929`
("Merge agent claude-skill work").

---

## 1. Bottom line

The one-click **Install** button (Settings → Command Line) fails on a default
Mac. The exact error is `NSCocoaErrorDomain` code `513`
(`NSFileWriteNoPermissionError`) — "The file couldn't be saved because you
don't have permission."

The cause is a **missing entitlement**:
`com.apple.developer.security.privileged-file-operations`.

Apple requires this entitlement for a sandboxed app to create a symlink in a
root-owned directory such as `/usr/local/bin`. Without it,
`NSWorkspace.requestAuthorization(to: .createSymbolicLink)` returns a
**non-privileged** authorization, shows **no admin panel**, and the write
fails with 513.

The entitlement **is available to Mac App Store apps** — it is made for them.
GuessWho ships on the App Store, TestFlight, and Setapp, so GuessWho can
request it. This is the sanctioned fix.

The app's install code is already correct and already matches the reference
apps (Muse/Allume, RubberDuck). The **only** missing piece is the entitlement.

---

## 2. The symptom (verbatim from the logs)

The installed Release app is at `/Applications/GuessWho.app`. The app logs each
install attempt. Three attempts, all identical:

```
04:19:08.472 INFO  MCPPreferencesView.install():416  "cli install attempt"
                    target=/Applications/GuessWho.app/Contents/MacOS/guesswho-cli
04:19:08.486 ERROR MCPPreferencesView.install():427  "cli install failed"
                    code=513 domain=NSCocoaErrorDomain
                    description="The file couldn't be saved because you don't have permission."
```

Key fact: the failure lands **15 milliseconds** after the button press. A
human cannot pass a password / Touch ID panel in 15 ms. So the admin-auth
panel **never appeared**. The authorization was granted with no real
privilege, and the write to root-owned `/usr/local/bin` was denied.

Read against the code path in
[`GuessWhoAppKitBridge.swift:60`](../App/GuessWhoAppKitBridge/GuessWhoAppKitBridge.swift):
`requestAuthorization(to:)` returned a **non-nil** authorization with **no**
error (it did not hit the error branch or the nil-auth branch), and then
`FileManager(authorization:).createSymbolicLink` threw 513.

---

## 3. Root cause

Two things decide whether the un-entitled install works. Both must be
understood:

1. **The entitlement.** Without
   `com.apple.developer.security.privileged-file-operations`, the system hands
   back a non-privileged authorization and does not prompt. There is no way to
   elevate.
2. **The target directory owner.** `/usr/local/bin` is `root:wheel` on a
   default Mac (created by the Xcode command-line tools). Homebrew, however,
   **chowns `/usr/local/bin` to the user**. On a Homebrew machine the plain
   (non-privileged) `createSymbolicLink` **succeeds with no panel**, on every
   macOS version. On a clean root-owned machine it **fails 513**, on every
   macOS version.

So the install only ever "worked" on machines where `/usr/local/bin` was
already user-writable (Homebrew), or when the user ran the manual `sudo`
fallback. On a default machine it has never worked without the entitlement.

The entitlement is exactly what makes the elevation real: with it,
`requestAuthorization` shows the admin panel, and the privileged `FileManager`
writes into the root-owned directory.

---

## 4. Evidence

### 4.1 GuessWho (this app)

- Installed Release build, App Store signature (`beta-reports-active=true`,
  `get-task-allow=false`, `app-sandbox=true`).
- App entitlements (`codesign -d --entitlements :-` on
  `/Applications/GuessWho.app`): `app-sandbox`,
  `files.user-selected.read-write`, application-groups, `network.server`,
  `personal-information.addressbook` / `.calendars`, `contacts.notes`, iCloud.
  **No `privileged-file-operations`.**
- `/usr/local/bin` on the test machine is `drwxr-xr-x root wheel`. The CLI
  target `Contents/MacOS/guesswho-cli` exists (25 MB). So the target is fine
  and the destination directory needs elevation — which did not happen.
- Live result: 513, no panel, three times.

### 4.2 Muse / Allume (reference app, verified live)

- Shipping App Store build. `codesign -d --entitlements :-` shows the same
  posture: `app-sandbox` + `files.user-selected.read-write`, and **no
  `privileged-file-operations`**.
- Same install code (`NSWorkspace().requestAuthorization(to:
  .createSymbolicLink)` + `FileManager(authorization:)`).
- **Adam ran the Install button in the shipping `Allume.app` and got the same
  failure** — no panel, 513. So this is an observed defect in the shipping
  reference app too, not a GuessWho-only problem. App Review never presses the
  button, so it ships undetected.

### 4.3 RubberDuck / Developer Duck (the cited precedent)

- The plan named RubberDuck as proof that no entitlement is needed. It is
  **not** a valid precedent.
- Shipping App Store Connect build (Developer Duck AI, v1.3.7, build 378).
  Signed entitlements: `app-sandbox` + `files.user-selected.read-write` +
  application-groups + `network.client` + keychain. **No
  `privileged-file-operations`.**
- Identical un-entitled install code
  (`NSWorkspace().requestAuthorization(to: .createSymbolicLink)`, symlink into
  `/usr/local/bin/duck`, target `Bundle.main.url(forAuxiliaryExecutable:)`). No
  privileged helper. No `SMJobBless` / `SMAppService` for the install (the app
  uses `SMAppService` only for Launch-at-Login).
- RubberDuck ships **only** through the Mac App Store. Its "it worked before"
  memory is best explained by a Homebrew (user-owned) `/usr/local/bin`, or the
  manual `sudo ln -s` fallback — see §3.

### 4.4 EssentialMCP (avoids the problem entirely)

- Sandboxed. Ships the CLI in the bundle. The Settings UI **only shows the
  in-bundle path plus a Copy button** — no symlink, no elevation, no
  entitlement. The user pastes the path into their MCP client config. This is
  the always-works baseline that GuessWho already has as the primary install.

---

## 5. Apple's rule (authoritative)

Apple documentation for the entitlement
(`com.apple.developer.security.privileged-file-operations`, macOS 10.15+):

> "Add this entitlement to your app **before you call**
> `requestAuthorization(to:completionHandler:)` to request permission to
> perform privileged file operations."

Apple DTS (Quinn "The Eskimo!"), Developer Forums thread 130092 —
"Installing a command line tool from my sandboxed Mac app" — is explicit that
the entitlement is a **Mac App Store** capability, verbatim:

> "Generally speaking, the Privileged File Operation entitlement is **for apps
> destined for the Mac App Store**, as there's no other way to accomplish the
> tasks it enables there (unlike non–Mac App Store apps, which don't have some
> of those restrictions). That said, we can enable it for this app…"

And, on why it is needed at all:

> "…sandboxed apps lack the permissions to create symlinks in `/usr/local/bin`
> without it."

Consequences:

- The entitlement **is required** for the sandboxed symlink into a root-owned
  directory.
- The entitlement **is available to Mac App Store apps** — GuessWho qualifies.
- *Developer ID* apps normally cannot use it; Apple enables it case by case.
  (This is the reverse of a common wrong assumption.)
- It is a **manually-approved, request-form** entitlement — the same kind of
  process as the `com.apple.developer.contacts.notes` request GuessWho already
  filed.

---

## 6. What the earlier plan got wrong

- [`plans/cli-mcp.md`](cli-mcp.md) lines 17, 95, 101 state the symlink needs
  "NO special entitlement key — only `app-sandbox=true` + the runtime auth
  API," and mark the question "CLOSED." That conclusion was inherited from
  Muse and **was never tested live on a clean (root-owned) machine**. It is
  wrong. Reopen it.
- [`plans/phase0-human-checklist.md`](phase0-human-checklist.md) §5 (lines
  88–92) repeats "the entitlement question is CLOSED (Muse ships it with no
  special key)." Correct it the same way.
- Code comment
  [`AppKitPlugin.swift:41`](../App/GuessWhoAppKitBridge/AppKitPlugin.swift)
  says "a runtime auth API, no bespoke entitlement." The comment in
  [`GuessWhoAppKitBridge.swift:65`](../App/GuessWhoAppKitBridge/GuessWhoAppKitBridge.swift)
  says "no authorized-DELETE counterpart" and frames the runtime auth as
  self-sufficient. Both should be corrected to record that the entitlement is
  required for a root-owned target.

The install code itself is correct and needs no change for the fix.

---

## 7. The fix (recommended)

Add the entitlement. Order matters, because the code signature must not name an
entitlement the provisioning profile does not authorize.

1. **Request the entitlement from Apple.** Use the request form at
   `developer.apple.com/contact/request/privileged-file-operations/`. State the
   use: a user-initiated, one-click install of an embedded command-line helper
   as a symlink in `/usr/local/bin`, gated by the system admin-auth panel.
2. **Enable it on the App ID** (`com.milestonemade.guesswho`) once granted, and
   regenerate the provisioning profiles for every channel.
3. **Add the key** to
   [`App/GuessWho/GuessWho-MacCatalyst.entitlements`](../App/GuessWho/GuessWho-MacCatalyst.entitlements):

   ```xml
   <key>com.apple.developer.security.privileged-file-operations</key>
   <true/>
   ```

   The entitlement belongs to the **app** (which runs the install through the
   AppKit bridge), not to the `guesswho-cli` helper.
4. **Re-provision and rebuild.** After the grant, verify with
   `codesign -d --entitlements :-` that the built app carries the key.
5. **Correct the docs and comments** listed in §6.

Expected result: pressing Install now shows the admin-auth panel; after the
user authenticates, the symlink is created in the root-owned `/usr/local/bin`,
and the 4-state resolver reports "Installed."

Note: the app already uses `NSWorkspace()` (a fresh instance), not
`NSWorkspace.shared`. This matches RubberDuck and is not the cause of the
failure. If anything misbehaves after the grant, switching to
`NSWorkspace.shared` (as in Apple's sample) is the first trivial thing to try.

---

## 8. Alternatives (if the entitlement is not wanted)

These avoid the entitlement. They are already partly present in the app and can
serve as fallbacks or as the whole solution.

- **A. Copy Path (already the primary install).** For an MCP client the symlink
  is unnecessary — the user pastes the absolute in-bundle helper path into the
  client config. Zero elevation, zero entitlement. This is the EssentialMCP
  pattern. It works today.
- **B. Manual `sudo` command (already in the app).** Show and let the user copy:

  ```sh
  sudo ln -s /Applications/GuessWho.app/Contents/MacOS/guesswho-cli /usr/local/bin/guesswho
  ```

  The user's own `sudo` bypasses the sandbox entirely. Reliable on every
  machine.
- **C. User-writable target directory.** Install the symlink into `~/bin` or
  `~/.local/bin` (no elevation) and tell the user to add it to `PATH`. Trade:
  the directory is not on the default `PATH`, so the command is not found until
  the user edits their shell profile.
- **D. Privileged helper via `SMAppService`.** A full privileged-helper
  install. Heavier to build and to maintain than the entitlement, and not
  needed once the entitlement is granted. Listed only for completeness.

Recommendation: keep A and B as the always-works fallbacks, and pursue the
entitlement (§7) so the **one-click** button works on a default machine.

---

## 9. Files to change

- [`App/GuessWho/GuessWho-MacCatalyst.entitlements`](../App/GuessWho/GuessWho-MacCatalyst.entitlements)
  — add the entitlement key (after the Apple grant + App ID enable).
- [`App/GuessWhoAppKitBridge/AppKitPlugin.swift`](../App/GuessWhoAppKitBridge/AppKitPlugin.swift)
  (~line 41) and
  [`App/GuessWhoAppKitBridge/GuessWhoAppKitBridge.swift`](../App/GuessWhoAppKitBridge/GuessWhoAppKitBridge.swift)
  (~lines 60–70) — correct the "no bespoke entitlement" comments.
- [`plans/cli-mcp.md`](cli-mcp.md) (lines 17, 95, 101) and
  [`plans/phase0-human-checklist.md`](phase0-human-checklist.md) (§5) — reopen
  and correct the "CLOSED / not needed" conclusion; link to this doc.
- Optional UX: on a 513 with no panel, the Install failure alert
  ([`MCPPreferencesView.swift`](../App/GuessWho/MCPPreferencesView.swift),
  `install()`) should point the user to the copyable `sudo ln -s` command
  instead of a bare "you don't have permission."

The install source code
(`GuessWhoAppKitBridge.installCommandLine`) needs no logic change.

---

## 10. Verification / test plan

On a **default machine where `/usr/local/bin` is `root:wheel`** (confirm first
with `ls -ld /usr/local/bin`):

1. Build/install a signed app that carries the new entitlement.
2. Press Install. **An admin-auth panel must appear** (password / Touch ID).
3. Authenticate. Confirm `/usr/local/bin/guesswho` exists and resolves back to
   `/Applications/GuessWho.app/Contents/MacOS/guesswho-cli`.
4. Confirm the Settings status row now reads "Installed."
5. Run `guesswho` from a fresh terminal to confirm it is on `PATH` and starts.

A machine with a Homebrew-owned `/usr/local/bin` is **not** a valid test — the
un-entitled write succeeds there and masks the defect. Test on a clean owner.

---

## 11. Sources

- Apple — [Privileged File Operations entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.security.privileged-file-operations)
- Apple — [`requestAuthorization(to:completionHandler:)`](https://developer.apple.com/documentation/appkit/nsworkspace/requestauthorization(to:completionhandler:))
- Apple Developer Forums (DTS, Quinn "The Eskimo!") —
  [thread 130092, "Installing a command line tool from my sandboxed Mac app"](https://developer.apple.com/forums/thread/130092)
- Live verification 2026-08-14: GuessWho (513 on root-owned dir), shipping
  Muse/Allume (same 513, confirmed by Adam), shipping Developer Duck build 378
  (App Store Connect signed entitlements — no `privileged-file-operations`).
