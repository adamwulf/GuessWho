# App Review readiness — CLI/MCP contacts access

Prepared for the held-open App-Review risk in `plans/cli-mcp.md`: Muse
proves the *packaging* (embedded helper, `/usr/local/bin` symlink via the
admin-auth panel, MCP concept) cleared review, but Muse never exposed
TCC-protected **Contacts** data to third-party agent processes — GuessWho
does, which is Guideline 5.1.1/5.1.2 (data use and sharing) territory that
has NOT been verified with Apple. This doc holds the purpose-string
rationale, the privacy nutrition-label answers, and the App Review notes
to paste into App Store Connect. **Nothing here has been submitted.**

## What the feature does (reviewer-relevant summary)

- The app embeds a helper (`Contents/MacOS/guesswho-cli`). An MCP client
  or terminal session the *user* configures spawns it; it exchanges
  newline-JSON with the running app through files (FIFOs) inside the
  app's own App Group container.
- The helper has **no data access of its own** — no Contacts/Calendar
  entitlements, no network sockets. Every answer comes from the app
  process, which enforces the user's toggles and TCC grants per call.
- Both surfaces are **OFF by default**. Enabling is an explicit user
  action in the app's Settings, and each surface additionally defaults to
  **read-only**. Writes touch only GuessWho's own data (notes, tags,
  favorites, guides) — never system contact or calendar records.
- The Apple contact **note** field (`com.apple.developer.contacts.notes`
  scope) is structurally excluded from the interface: the wire uses
  positive field allowlists with no note field, enforced by adversarial
  tests. The entitlement exists solely for the app's own note UI.
- Every agent write is recorded in a device-local activity log the user
  can read in Settings, and agent deletes are soft-deletes restorable
  from Settings → Recently Deleted.

## NSContactsUsageDescription (updated in `App/GuessWho/Info.plist`)

> GuessWho lets you read and edit the Notes on your contacts, just like
> the Contacts app. If you turn on assistant or terminal access in
> GuessWho’s settings, tools you set up on this Mac can look up your
> contacts through GuessWho. Everything stays on your device, in your own
> iCloud, and is never sent to any server.

Rationale: the first sentence is kept **verbatim** — it mirrors the
purpose text in the pending contacts-notes entitlement request
(ID 54G9JZR59F, submitted 2026-07-04); changing it mid-review would make
the request and the binary disagree. The added sentence discloses the
user-enabled local agent interface in plain language, per 5.1.1's
requirement that the purpose string cover all uses of the protected data.

## Privacy nutrition label (App Store Connect)

The nutrition label declares data **the developer (or their partners)
collects** — i.e. data transmitted off the device to the developer. The
CLI/MCP interface transmits nothing to us: contact data moves between two
processes on the user's own machine, at the user's instruction, and the
sync path remains the user's private iCloud container (not "collection"
under Apple's definition, same as the existing app).

- **No new nutrition-label entries are required** for this feature; the
  label stays whatever it is today (the app itself collects nothing).
- What the user's own MCP client does with tool results (e.g. Claude
  sending them to its model provider) is that client's disclosure, not
  ours — identical to the user copying contact info into any app. The App
  Review notes below say this explicitly so the reviewer doesn't have to
  infer it.
- Action item when submitting: re-verify in App Store Connect that the
  label currently claims no data collection; if anything is listed,
  confirm the entries still describe only the app's own behavior.

## App Review notes (paste into the Review Notes field)

> **About the optional assistant/terminal access feature**
>
> GuessWho includes an optional, off-by-default interface that lets tools
> the user configures on their own Mac (an AI assistant app or the
> Terminal) query the user's contact and event data through GuessWho.
>
> Mitigations and scope:
> - **Off by default, explicit opt-in.** Two toggles in the app's
>   Settings (⌘,) — one for assistants, one for Terminal — both ship OFF.
>   Nothing is reachable until the user enables one.
> - **Read-only by default.** Even when enabled, editing is a second
>   opt-in. Writes only ever touch GuessWho's own data (notes, tags,
>   favorites) — never the system Contacts/Calendar records themselves.
> - **Local-only IPC, no network.** The embedded helper
>   (Contents/MacOS/guesswho-cli) exchanges data with the app through
>   files inside the app's own App Group container. The helper opens no
>   network connections and has no Contacts or Calendar access of its
>   own; contact data never leaves the machine and is never sent to us.
> - **Per-request enforcement in the app.** The app process checks the
>   toggles and the system Contacts/Calendar permission on every request.
>   If the user revokes Contacts access in System Settings, the interface
>   returns nothing.
> - **Transparency and undo.** Every change made through the interface is
>   listed in Settings ("Agent Activity"), and deletions are recoverable
>   by the user in Settings → "Recently Deleted".
> - **The Apple contact Notes field is excluded.** The contacts-notes
>   entitlement covers the app's own note-editing UI only; the assistant/
>   terminal interface cannot read, write, or search the Apple note field
>   (enforced by structural field allowlists and automated tests).
>
> To demo: open GuessWho → ⌘, → enable "Terminal access" → use the Copy
> Path button, then in Terminal run the copied path with the argument
> `probe` (packaging diagnostic) or configure any MCP client with the
> copied path and `run`.

## Timing — coordinate with entitlement request 54G9JZR59F

The contacts-notes entitlement request ("Replacement of Contacts"
category) is pending; TestFlight builds also require the granted
entitlement. Recommended sequencing:

1. **Hold the first CLI/MCP-enabled App Store / TestFlight submission
   until the entitlement request resolves.** Two novel review surfaces at
   once (special entitlement + agent egress of Contacts data) risks a
   conflated rejection that muddies both threads.
2. If Apple asks questions on the entitlement request meanwhile, do NOT
   volunteer the agent interface into that thread — it is orthogonal (the
   interface excludes the note field entirely), and the request's purpose
   text remains accurate as submitted.
3. When the entitlement lands (or is abandoned), submit the CLI/MCP build
   with the purpose string above unchanged and the App Review notes
   pasted verbatim.

## Human checklist (not automatable)

- [ ] Verify the privacy nutrition label in App Store Connect still
      declares no data collection (or that existing entries remain
      accurate) before submitting.
- [ ] Paste the App Review notes into the Review Notes field of the
      first submission that ships the feature.
- [ ] Confirm the admin-auth symlink panel appears and works on an
      exported (non-Debug) build.
- [ ] TestFlight beta review of the helper-embedding build (also gated
      on the entitlement grant).
- [ ] Re-check sequencing against the state of request 54G9JZR59F at
      submission time.
