# Phase 0 — remaining verification checklist (needs Adam's hands)

Phase 0's packaging skeleton is BUILT and locally verified (see the Phase 0
commits on this branch). Everything below either needs App Store Connect /
distribution signing, a shipped (quarantined) artifact, or a GUI app run —
none of which the agent harness can perform. Per the plan
(`plans/cli-mcp.md`, Phase 0 exit criteria), these are the last steps to
CLOSE Phase 0; the Setapp items are deferred until that channel exists and do
NOT block Phase 1.

## Already verified locally (for reference — no action needed)

On the local Debug + Release Catalyst builds and a local Release archive
(`xcodebuild archive`), all with `-derivedDataPath .build/DerivedData`:

- `GuessWho.app/Contents/MacOS/guesswho-cli` exists; universal
  (x86_64 + arm64); native macOS Mach-O (`LC_BUILD_VERSION platform 1`,
  app itself is platform 6 / Catalyst).
- Helper entitlements exactly mirror Muse: `app-sandbox`,
  `files.user-selected.read-only`, the App Group — and `get-task-allow`
  present in Debug, ABSENT in Release + archive.
- Hardened runtime flag on the helper (`flags=0x10000(runtime)`).
- App + helper both carry the SAME per-channel group expanded from the ONE
  shared var (INV-4): `T68Z94627S.com.milestonemade.guesswho.cli.debug`
  (Debug) / `…​.cli` (Release).
- `guesswho-cli probe` (run directly): reads the group id from its embedded
  Info.plist, resolves the container, read+writes a scratch file (crit 2),
  and its FIFO line was received by a reader holding the app-side path
  (crit 4's CLI half, app side simulated with mkfifo + head).
- iOS Simulator build green with NO helper embedded (INV-5).
- Archive contains only `GuessWho.app` (SKIP_INSTALL respected).

## 1. In-app FIFO handshake on a real app run (crits 3 + 4, local half) — ~3 min

1. Run the GuessWho app (Catalyst, Debug or Release) and enable the
   debug-mode toggle in Settings.
2. Check the app log (`app.log`) for `cli probe listener ready` — it prints
   the helper path, group id, and FIFO path.
3. In Terminal:
   `<path-to>/GuessWho.app/Contents/MacOS/guesswho-cli probe`
4. PASS = probe prints the SAME container path the app logged, and the app
   logs `cli probe connected pid=…`. If the two processes print DIFFERENT
   container paths → STOP: group-id/entitlement mismatch (plan's debugging
   order: fix this before anything else).

## 2. TestFlight upload + beta review (closes Phase 0) — days

- Archive + upload the helper-embedding build to App Store Connect;
  clear beta review. (First upload with the embedded tool is the actual
  packaging gate Muse already cleared; expect no issues, but this is the
  proof.)
- Watch for: ITMS warnings about the embedded binary, missing distribution
  signing on `guesswho-cli`, or the `.cli` App Group (TeamID-form groups
  need no portal registration, but confirm automatic signing is happy on
  the distribution path).

## 3. Exported/TestFlight artifact checks (crit 1) — ~5 min

On the TestFlight-installed (or exported-for-distribution) app:

```sh
codesign -dvvv /Applications/GuessWho.app/Contents/MacOS/guesswho-cli
codesign -d --entitlements - /Applications/GuessWho.app/Contents/MacOS/guesswho-cli
```

- PASS = TeamIdentifier `T68Z94627S`, hardened-runtime flag, the 3-key
  entitlements (NO `get-task-allow`), group `T68Z94627S.com.milestonemade.guesswho.cli`.

## 4. Client-spawn past Gatekeeper from the REAL install (crit 4, shipped half) — ~10 min

A locally built binary has no quarantine xattr and passes spuriously — this
MUST use the TestFlight/MAS-installed artifact.

1. GuessWho (TestFlight install) running, debug mode ON.
2. Point an MCP client at the helper so the CLIENT spawns it (the app never
   does), e.g. `.mcp.json`:
   ```json
   {"mcpServers": {"guesswho": {"command": "/Applications/GuessWho.app/Contents/MacOS/guesswho-cli", "args": ["probe"]}}}
   ```
   (Phase 0 has no MCP server — `run` is a stub that exits with an error —
   so `probe` is the binary-checkable Phase-0 handshake; the client will
   report the server as failed AFTER the probe line lands, which is fine.
   Spawning `probe` from a fresh Terminal also exercises the same
   Gatekeeper path.)
3. PASS = the app logs `cli probe connected pid=…` and macOS shows no
   Gatekeeper block.

## 5. Symlink admin-auth panel — NOT Phase 0 work

The `/usr/local/bin/guesswho` symlink install code
(`NSWorkspace.requestAuthorization(.createSymbolicLink)`) is Phase 3 work;
the entitlement question is CLOSED (Muse ships it with no special key).
Nothing to verify until Phase 3 writes that code.

## 6. Setapp channel — DEFERRED (tracked)

No Setapp channel exists (no Developer-ID config, no notarization lane, no
`ProvisioningService` wiring). Standing it up is separate, sized work. When
it exists:
- add `CLIAppGroup-Setapp.xcconfig` (`GUESSWHO_CLI_CHANNEL_SUFFIX = .setapp`)
  per the TODO in `CLIAppGroup-Shared.xcconfig`,
- re-run crits 1–4 on the notarized Setapp build (notably: notarization
  rejects `get-task-allow` on any embedded binary — our Release entitlements
  already omit it).
Per the plan, this re-run does NOT block Phase 1.

## Known Phase-1 risk discovered in Muse's source — MATERIALIZED + FIXED (2026-07-17)

Muse embeds its helper via a nested-`xcodebuild` script phase, NOT a target
dependency, because when the Catalyst app and the macOS tool BOTH depend on
`mcp-template` (→ swift-sdk → swift-nio) in one build graph, the SwiftPM
planner emits duplicate compile commands for shared C targets
("Multiple commands produce …") and build planning aborts. Phase 0's
in-project dependency was fine (no shared packages), but once Phase 1 put
`mcp-template` in both targets, `xcodebuild archive` (default DerivedData)
failed exactly this way — ~15 "Multiple commands produce
…/UninstalledProducts/macosx/<X>" errors. (The earlier "local Release
archive green" check above ran with `-derivedDataPath .build/DerivedData`,
which masks the collision — archive-verify WITHOUT that flag.)

The Muse fallback is now IMPLEMENTED: `guesswho-cli` moved to its own
`App/guesswho-cli.xcodeproj` (Debug+Release configs matching the app's),
and the app target's "Build and Embed guesswho-cli" Run Script
nested-builds it into an isolated derived-data path under TARGET_TEMP_DIR,
copies the binary to `Contents/MacOS/guesswho-cli`, and codesigns it with
the sed-expanded `$(GUESSWHO_CLI_APP_GROUP)` entitlements (PlistBuddy
get-task-allow strip + secure timestamp for non-Debug). Items 2–4 above
are unchanged — the TestFlight upload remains the shipped-artifact proof.
