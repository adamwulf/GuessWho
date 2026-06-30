# Updating a note-bearing Apple contact without the notes entitlement (NSCocoaErrorDomain 134092)

**Status:** research + recommendation only. No fix has been verified on a
distribution-signed build (neither the author nor any reachable tooling can
reproduce the bug — see [Why nobody can locally verify](#why-nobody-can-locally-verify)).
**Date:** 2026-06-29. **Researcher:** `agent-4f91c383` (with forum/SO sweep by
sub-agent `agent-28aab3ee`).

---

## TL;DR — ranked recommendation

0. **NEW & possibly decisive — the bug appears to be Mac Catalyst-only (iOS
   works).** Adam reports the same unentitled binary saving the same contact
   *succeeds on iOS, fails with 134092 only on Catalyst.* macOS/Catalyst runs a
   stricter sandbox+TCC+code-signing privacy stack than iOS (incl. the macOS-only
   `com.apple.security.personal-information.addressbook` sandbox grant), which
   makes a platform difference mechanistically plausible — though Apple's docs say
   the notes entitlement applies to *both* iOS 13+ and macOS 13+, so this is an
   enforcement divergence, not a documented one. **First confirm it isn't a
   confound** (the iOS contact may simply lack the synced note — test step A). If
   confirmed, the recommendation below becomes **platform-scoped: degrade only on
   Catalyst, leave iOS untouched.** Full treatment:
   [Platform difference: iOS vs Mac Catalyst](#platform-difference-ios-vs-mac-catalyst-this-likely-reframes-the-whole-fix).

1. **Graceful-degrade is the recommended strategy (high confidence) — scoped to
   the affected platform (Catalyst) if #0 confirms.** No source — Apple docs,
   Apple Developer Forums (threads 723695, 718743, 757133, 125408), Stack
   Overflow, or third-party plugin changelogs — documents *any* client-side way to
   `update()` a note-bearing contact without the
   `com.apple.developer.contacts.notes` entitlement and without 134092. The
   failure is in the **Contacts daemon's** `willSave` re-index of the *stored*
   record, which the client's `keysToFetch` / `CNMutableContact` shape cannot
   influence. So the package should: catch the faulting error, persist the
   user's edit in our own sidecar storage as the source of truth for the changed
   field, and soft-fail (not hard-error) the Contacts write — only when the error
   matches a **precise predicate** (below) so we never over-degrade on unrelated
   save failures.

   ⚠️ **Big caveat that constrains this recommendation:** graceful-degrade means
   "don't crash / don't show a scary error and keep the edit in sidecar." It does
   **not** mean the change reaches Contacts.app. GuessWho's sidecar today stores
   *GuessWho-only* data (notes, tags, links, favorites); it does **not** store
   mirror copies of Apple fields like phone/email/name. Persisting a
   phone-number edit "in our own sidecar" is **not currently a thing the storage
   model does**, and adding it is a real design change with its own
   source-of-truth questions. See [What graceful-degrade actually buys you](#what-graceful-degrade-actually-buys-you).

2. **Request the entitlement (the only *real* fix; out of scope now per Adam).**
   Every source that reports the problem *solved* solved it by adding the
   entitlement. It is the sole documented cure for both the read path and the
   save path. Adam has deferred this to post-App-Store-launch (Apple approval
   required). Listed here for completeness and because it reframes #1 as a
   *bridge until the entitlement lands*, not a permanent architecture.

3. **Everything else (candidates 1–5) — do NOT rely on any of them.** Fresh
   `CNMutableContact`, non-unified backing card, `note = ""`, vCard, and
   "newer OS fixes it" all fail on evidence or mechanism (details per candidate
   below). A couple are *worth including in the on-device test matrix* as
   cheap longshots (fresh mutable contact; `shouldRefetchContacts = false`),
   but the recommendation does not depend on them.

4. **Why Debug works but TestFlight fails (Adam's sub-question):** the asymmetry
   is real and reproduced, but the exact enforcement lever is **undocumented**.
   Best-supported inference: a development-signed, `get-task-allow` build runs
   under relaxed restricted-entitlement/TCC enforcement, so the daemon's note
   fault is not denied; a distribution signature is enforced strictly. A cheap
   on-device `codesign -d --entitlements` diff (test step 7) settles which lever.
   Full treatment: [Why Debug works / TestFlight fails](#why-debug-works--testflight-fails-the-same-code-neither-build-declaring-the-entitlement).

---

## The mechanism (why the obvious fixes don't work)

The crash is **not** in our process deciding it lacks a key. It is the Contacts
daemon (`contactsd`), during `CNSaveRequest.execute()`, running
`-[CNCDContact willSave]` → `-[ABCDContactIndex stringForIndexing]` →
`-[CNCDContact _newStringForIndexing]` → `_PF_FulfillDeferredFault` →
`_PFFaultHandlerLookupRow` → `objc_exception_throw`. The daemon re-indexes the
**stored** contact's search string, which *includes the note*, faults the note
row, and that fault is denied for an unentitled app, throwing
`NSCocoaErrorDomain 134092`. (Stack from the GuessWho device `app.log`, per the
confirmed diagnosis.)

The load-bearing consequence: the note is re-indexed **from what is stored in the
database, not from what the client put in the `CNMutableContact`.** Apple's own
docs say of `update(_:)`: *"Note that the contact may be modified when the save
request is executing."*[^update] So the daemon reads/writes fields the client
never touched. Anything the client does to the mutable object it submits —
omit the note key, build a minimal object, blank the note — changes what the
*client* sends, never what the *daemon* re-indexes from the store. That is why
"omit `CNContactNoteKey`" (which GuessWho already does
[^adapter-keys]) is **necessary but not sufficient**, and it is the single fact
that sinks candidates 1–4.

---

## Why Debug works / TestFlight fails (the same code, neither build declaring the entitlement)

**Adam's direct question:** why does the *identical* `CNSaveRequest` succeed in a
Debug/dev-signed build but throw 134092 in a TestFlight/distribution build, when
**neither** build declares `com.apple.developer.contacts.notes`?

**Honest headline: there is no single Apple sentence that says "the notes gate is
skipped for development-signed code."** The dev-vs-distribution asymmetry is
*observed and reproduced* (by the GuessWho device log, and verbatim in the forum:
the OP of thread 723695 reports it *"works… In debugging mode inside Xcode"* but
*"if I execute the compiled release binary… The contact will not be updated"*)
[^thread723695-debug], but the *exact* enforcement lever is, to the best of this
research, **undocumented platform behavior.** Below is the best-supported
inference, with each load-bearing lever rated.

### How effective entitlements are derived (the documented part)

Apple's TN2415 is explicit that an app's runtime entitlements come from the
profile that signed it: *"the entitlements corresponding to the app's enabled
Capabilities/Services are transferred to the app's signature from the provisioning
profile Xcode chose to sign the app,"* and the OS validates *"that entitlements
match across the app's signature and the app's embedded provisioning
profile."*[^tn2415] So the dev build and the distribution build differ in exactly
one input that matters here: **which provisioning profile signed them, and what
that profile carries.** That is the soil all the candidate levers grow from.

### Candidate levers, rated

1. **`get-task-allow` + development code signature relaxes daemon/TCC enforcement
   — BEST-SUPPORTED INFERENCE for GuessWho's case, but NOT definitively
   documented (medium confidence).** A development-signed build carries
   `get-task-allow` (it is *"intended for the development process, as it enables
   programmers to debug the app"* and *"only Development profiles"* whitelist
   it)[^gettaskallow-doc][^gettaskallow-afine]; a distribution build does not.
   Security research documents that `get-task-allow` *"creates a bypass for the
   Hardened Runtime"* and that a process can *"inherit all the trust you gave to
   the original app, so silently access the TCC-protected resources."*
   [^gettaskallow-afine] **Caveat I must state plainly:** that research describes
   bypass via *code injection into* a debuggable process, **not** the daemon
   directly waiving the note-fault for the debuggable process's own save. So this
   supports the *direction* (debuggable/dev-signed code runs under relaxed privacy
   enforcement) but does **not** prove the specific claim that `contactsd` skips
   the note-read gate for a dev-signed caller. Treat as the most likely mechanism,
   not a confirmed one.

2. **The notes capability is silently present in Debug but stripped from Release
   signing — PLAUSIBLE but probably NOT GuessWho's case (low-medium confidence).**
   Forum thread 757133 documents the Contact Notes capability *"appears for a few
   seconds, then disappears when I move to a different tab and return. This does
   not happen for the 'Debug' configuration"* — i.e. Xcode kept the entitlement on
   the Debug signing config but dropped it from Release.[^thread757133-debug] This
   is a real, documented Debug-vs-distribution divergence. **But it only applies if
   the project *ever added* the capability.** The GuessWho confirmed context says
   *neither* config declares the entitlement, so this specific "it's silently in
   Debug only" story likely does **not** explain GuessWho — unless an Xcode-managed
   automatic-signing artifact is injecting it into the Debug signature without it
   appearing in the `.entitlements` file. **Worth ruling out on device** (dump the
   actual signed entitlements of both builds — see test step 7).

3. **Different bundle id (`com.milestonemade.guesswho.debug`) → separate, possibly
   looser TCC record — UNLIKELY to be the lever (low confidence).** GuessWho's
   Debug build uses a `.debug`-suffixed bundle id, App Group, and iCloud container
   (project memory: "Debug build identifiers"). A distinct bundle id gets its own
   TCC authorization record and its own first-run Contacts prompt. **But** a TCC
   *grant* governs whether you may read contacts at all (the `requestAccess`
   prompt); it does **not** grant the *notes* sub-permission, which is gated by the
   `com.apple.developer.contacts.notes` *entitlement*, not by TCC consent. So a
   different/looser TCC record would explain a different *access* outcome, not the
   *note-fault* outcome. Most likely a red herring for 134092 specifically, though
   it should be controlled for in testing.

4. **The development profile implicitly granting broader Contacts access — NOT
   SUPPORTED (low confidence).** No source shows a development profile auto-adding
   the notes entitlement or broader Contacts scope beyond what its capabilities
   declare. TN2415's model is that the profile is an allowlist whose entitlements
   must *match* the signature[^tn2415]; it does not describe development profiles
   silently widening restricted scopes. No evidence for this lever.

### Best-supported answer

For GuessWho — where neither `.entitlements` file declares the notes entitlement —
the most defensible explanation is **lever 1**: the development build is signed
with `get-task-allow` and a development certificate, and the system enforces the
restricted private-data (notes) gate **leniently for debuggable, development-signed
processes and strictly for distribution-signed ones.** This is consistent with
every observation (works in Xcode/Debug, fails in the release binary / TestFlight)
and with the general security model that `get-task-allow` relaxes Hardened-Runtime
/ TCC boundaries — but **it is an inference from indirect sources, not a
documented Apple guarantee.** The cleanest way to *confirm which lever* is live is
to dump and compare the actually-signed entitlements of both builds (test step 7);
if the Debug signature contains `com.apple.developer.contacts.notes` or a
`com.apple.private.*` contacts entitlement that Release lacks, the cause is lever 2;
if both signatures are identical except for `get-task-allow`, the cause is lever 1.

---

## Platform difference: iOS vs Mac Catalyst (this likely reframes the whole fix)

**New field data from Adam:** the *same unentitled binary* saving the *same
contact* **succeeds on iOS but fails with 134092 only on Mac Catalyst.** If that
holds up (see the confound in [step A](#confound-to-eliminate-first) below), it is
the single most important fact in this document, because it means the bug is
**Catalyst/macOS-only** and the fix should be **platform-scoped**, not global.

### Why a platform difference is mechanistically plausible (high confidence on the model; medium on it being THE cause)

The iOS and macOS Contacts *privacy enforcement models are genuinely different*,
and a Catalyst app runs under the **macOS** model:

- **macOS has an App-Sandbox address-book entitlement that iOS does not.**
  `com.apple.security.personal-information.addressbook` is documented **macOS-only**
  ("Available on: macOS 10.7+") and grants App-Sandbox *"read-write access to
  contacts in the user's address book."*[^addressbook-ent] There is **no iOS
  counterpart** — iOS gates Contacts purely through the TCC prompt +
  `NSContactsUsageDescription`.[^accessing-store] GuessWho's Catalyst build carries
  this macOS sandbox entitlement (per project config); the iOS build cannot and
  does not. So on Catalyst the Contacts write passes through a **macOS sandbox +
  macOS TCC + macOS code-signing** enforcement stack that simply isn't present on
  iOS.
- **The daemon-side note-fault is observed on the Mac console, and the iOS path is
  faster.** In thread 723695 the `[api] Attempt to read notes by an unentitled
  app` line is reported on *"the console in the Mac,"* and a reporter notes the iOS
  save (~0.005s) is far faster than macOS (~0.35s)[^thread723695-platform] —
  consistent with macOS doing extra indexing/validation work (the `willSave`
  re-index that faults) that iOS skips or enforces differently.
- **Catalyst inherits the stricter macOS enforcement (analogous corroboration).**
  The "works on iOS, fails on Catalyst" pattern is a known class of Catalyst issue:
  a community answer on an analogous *Keychain* entitlement notes that *"Mac
  Catalyst requires additional considerations for entitlements and signing because
  it's essentially an iOS app running in a macOS environment with stricter sandbox
  (App Sandbox) enforcement."*[^catalyst-macos-model] This is not Apple-official and
  not about Contacts notes specifically, so treat it as *pattern* corroboration —
  it explains *why* the same binary diverges, not proof that Contacts notes is one
  such case.

### What the documentation says (the honest counterweight)

**Apple's docs do NOT describe the notes entitlement as macOS-only.** Both the
`CNContact.note` doc and the "Accessing the contact store" article state the
entitlement is required *"in iOS 13, macOS 13, or later"*[^notedoc][^accessing-store-notes]
— i.e. *by the written contract* the gate applies to **both** platforms equally.
So the iOS-works/Catalyst-fails behavior is most likely an **enforcement /
implementation divergence at the `contactsd` re-index layer** (macOS faults the
stored note where iOS does not), **not** a documented API difference. I found **no
Apple doc or forum post that explicitly states the 134092 save-fault is
macOS/Catalyst-only**; this is an inference from the platform model + the field
report. Treat "Catalyst-only" as **strongly indicated but not yet confirmed**
until step A rules out the confound.

### Confound to eliminate FIRST

⚠️ **Before concluding a true platform difference, rule out the boring
explanation:** the iOS save may "work" simply because **that device's copy of the
contact has no non-empty note** at save time — e.g. iCloud/CardDAV sync lag, or the
note physically lives on a backing account card that isn't present/linked on the
iOS device. The bug is triggered by the *presence of a stored note on the record
the daemon resolves*, so a note-free copy on iOS would succeed for a reason that
has nothing to do with the platform. **Adam must confirm the iOS contact actually
carries the same non-empty note** (open it in Contacts.app on the iOS device and
verify the note text is present) before we treat this as a platform difference.
This is **test step A** below and gates the whole platform conclusion.

### Fix implications if it IS Catalyst-only (this changes the ranked recommendation)

If step A confirms Catalyst-only:

1. **Scope the graceful-degrade to Catalyst.** The detection predicate and the
   soft-fail path should be gated `#if targetEnvironment(macCatalyst)` (or a
   runtime `ProcessInfo.isMacCatalystApp` / `isiOSAppOnMac` check). The iOS build
   keeps the **current unmodified unified-contact update path** — no degradation,
   no behavior change — because it doesn't hit the fault. This is strictly better
   than a global degrade: iOS users get full Contacts writes; only Catalyst
   soft-fails the note-bearing case.
2. **The "graceful-degrade can't write Apple fields" cost shrinks dramatically.**
   The functional casualty (a phone/name edit not reaching Contacts.app for a
   note-bearing contact) would be **Catalyst-only**, and iOS — likely the primary
   usage surface — is unaffected. That makes graceful-degrade much more palatable
   as a bridge, and lowers the urgency of the sidecar-mirrors-Apple-fields design
   question for iOS.
3. **The macOS sandbox addressbook entitlement is almost certainly NOT the lever
   to remove.** Dropping `com.apple.security.personal-information.addressbook`
   would remove Contacts read-write access entirely on Catalyst (it's the sandbox
   grant for *all* contact access, not a notes sub-gate) — it does not gate the
   note specifically and removing it makes things worse, not better.[^addressbook-ent]
   Do not touch it as a "fix."
4. **Adopt-on-first-write (the `guesswho://` URL mint) is also a contact write**,
   so on Catalyst it will fault for note-bearing contacts too — the platform-scoped
   degrade path must cover the mint, not just user-field edits.

### Updated ranked recommendation (superseding the TL;DR if step A confirms Catalyst-only)

- **#1 becomes: platform-scoped graceful-degrade — degrade ONLY on Mac Catalyst**,
  with the precise predicate; leave iOS on the current full-write path. Everything
  in [Recommended strategy](#recommended-strategy-graceful-degrade-with-a-precise-error-predicate)
  still applies, now wrapped in a Catalyst gate.
- If step A shows the iOS contact had **no** note (confound), then there is **no
  proven platform difference**, the original global recommendation stands, and we
  simply haven't yet seen iOS fail because we haven't tested iOS with a genuinely
  note-bearing synced contact.

---

## Per-candidate verdicts

### Candidate 1 — Build a FRESH `CNMutableContact` (only `identifier` + the changed field) and `update()` it

**Verdict: almost certainly does NOT work (medium-high confidence). Mechanism is against it; no positive report exists. Cheap enough to keep in the test matrix as a longshot.**

- `CNSaveRequest.update(_:)` requires the contact to already exist
  (else `recordDoesNotExist`)[^update][^saverequest]; it matches on the
  identifier, so a minimal mutable contact is in principle update-capable.
- **But** Apple's partial-update contract is purely about what the *client* may
  *touch*: *"You may modify only those properties whose values you fetched from
  the contacts database … you can modify only those properties for which a value
  exists."*[^mutablecontact] It says nothing about the daemon not re-indexing
  the stored note at save time. The 134092 fault is daemon-side, so reducing the
  client object's field set does not address the cause (see
  [The mechanism](#the-mechanism-why-the-obvious-fixes-dont-work)).
- No forum/SO post reports a minimal-fresh-`CNMutableContact` succeeding where a
  `mutableCopy` failed. The canonical update-path report (thread 723695) failed
  with the note key already excluded.[^thread723695]
- Note also: a hand-built `CNMutableContact` whose `identifier` you set yourself
  is **not** how the framework expects updates; the supported pattern is
  fetch → `mutableCopy()` → edit → `update()`. Departing from it risks a
  *different* failure even before the note re-index. **Not recommended.**

### Candidate 2 / 3 — Write the NON-unified backing card (`contact(withIdentifier:)`) instead of the unified contact

**Verdict: NOT a usable fix here (medium confidence on mechanism; high confidence on the architectural objection).**

- Where the note physically lives: a unified contact is an OS-assembled
  composite of per-account backing cards; the `note` is a property of *a* backing
  card (typically the iCloud/local card that owns it). I found **no source**
  proving that saving a *different* backing card avoids the daemon's re-index of
  the contact's full indexed string — and the re-index is keyed on the contact
  the daemon resolves, so this is unproven at best. **UNKNOWN whether it avoids
  134092**, and no positive report exists.
- **Architectural objection (decisive):** the package's hard invariant is that it
  *only ever* uses unified contacts — `unifiedContact` / `unifiedContacts`, never
  the non-unified `contact(withIdentifier:)` — and identity is keyed on the
  unified `localID`. [^identity-unified] Switching writes to a per-account
  backing card would (a) break that invariant, (b) require resolving and
  persisting a non-unified identifier (which the identity doc forbids), and
  (c) reopen the unification-stability problems the GuessWho-ID design exists to
  avoid. Even if it *did* dodge 134092, the cost is not worth it for a
  field-write workaround. **Do not pursue.**

### Candidate 4 — Set `note = ""` (empty) on the mutable copy; and the vCard path

**Verdict: empty-note does NOT help (medium-high confidence — direct forum evidence). vCard cannot update at all (high confidence — Apple docs).**

- **Empty note:** Even a blank note triggers the re-index/warning. In thread
  723695, a second reporter (`nigelhamilton`) states the contact *"actually has a
  blank note"* yet still hits the warning.[^thread723695-blank] And thread 718743
  surfaces the daemon log line *"Attempt to write notes by a pre-Fall-2022
  app"*[^thread718743] — i.e. the daemon gates the note *write/index path*
  itself, independent of content. Setting `note = ""` is also a *write to the
  note field*, which is exactly what the unentitled app may not do. **No help.**
- **vCard (`CNContactVCardSerialization`):** it only converts *to* vCard
  (`data(with:)`) and *from* vCard (`contacts(with:)`).[^vcard] It is **not a
  store-write path** — to persist a deserialized contact you still call
  `CNSaveRequest.update()`/`add()` + `execute()`, hitting the *same* daemon
  re-index. It is therefore add-or-update-incapable on its own and **cannot
  bypass the bug.** (Separately, vCard can't represent the note for an unentitled
  app, so it's also lossy for that field — but the dispositive point is it isn't a
  write path.) **No help.**

### Candidate 5 — Is it fixed in a newer OS? (and note the platform axis)

**Verdict: NO evidence of a fix on the SAVE path in any shipping OS (medium-high confidence). Reproductions span iOS 13 → macOS 14.5 (Jun 2024); nothing reports it cured. The bigger story here is the *platform* axis, not the version axis — see [Platform difference: iOS vs Mac Catalyst](#platform-difference-ios-vs-mac-catalyst-this-likely-reframes-the-whole-fix).**

- Reports run from the entitlement's introduction (iOS 13 / macOS 13, Fall 2022)
  through the most recent dated post in thread 723695 (`await`, Jun 2024,
  **macOS 14.5 (23F79)**).[^thread723695-versions] No poster in any thread reports
  the save-path 134092 fixed in a later OS.
- The one *"fixed to work without the notes entitlement"* changelog I found
  (MBS FileMaker plugin v10.1) is about **fetching** functions
  (`CNContactStore.Contacts`, `UnifiedMeContact`, `ContactsInGroup`,
  `ContactsMatchingName`) — i.e. the read-side `unauthorizedKeys` problem, fixed
  by *not requesting the note key*. It does **not** touch the save path.[^mbs]
- **OS-naming verification (the task asked to verify, not trust memory):** as of
  today (2026-06-29) the *current shipping* releases are **iOS 26.x / macOS 26
  "Tahoe"** (Tahoe 26.5.2 shipped 2026-06-29; macOS 26 released 2025-09-15).
  **iOS 27 / macOS 27 "Golden Gate"** were unveiled at WWDC 2026 (2026-06-08) and
  ship *later in 2026* — they are not yet released.[^osnaming-wiki][^osnaming-apple][^osnaming-mr]
  So the brief's phrase "iOS 27 / macOS 26 era" should read **iOS 26 / macOS 26
  (Tahoe) is current; 27 is announced-but-unshipped.** I have **no evidence**
  about behavior on the unreleased 27 builds; treat any "maybe 27 fixes it" as
  pure speculation. The on-device test plan should run on whatever the current
  26.x build is.

### Bonus candidate — `CNSaveRequest.shouldRefetchContacts = false`

**Verdict: unlikely to help on mechanism, but a zero-cost line to include in the test matrix (low confidence it works).**

- `shouldRefetchContacts` (default `true`, iOS 15.4+/macOS 12.3+) controls
  whether the save request **refetches** added/updated contacts *after* execute,
  to *"reduce the save request's execution time."*[^refetch] That is a
  *client-side post-save refetch*, conceptually distinct from the daemon's
  *pre-save `willSave` re-index* that throws 134092. So on mechanism it should
  not suppress the fault.
- It costs one line to set and is on the save path, so it's worth trying on the
  distribution build as a longshot — but **do not design around it.**

---

## Recommended strategy: graceful-degrade, with a precise error predicate

### Detecting *this* error and not over-catching

`NSCocoaErrorDomain` code **134092** is the right *necessary* condition but is
**not specific by itself**: 134092 has **no named constant** in the public
`CoreDataErrors.h` — it sits unnamed between `NSPersistentStoreUnsupportedRequestTypeError`
(134091) and `NSPersistentStoreIncompatibleVersionHashError` (134100), inside the
persistent-store error band, so it is an internal Core Data faulting failure that
*any* deferred-fault denial could in principle raise.[^coredataerrors] The
existing code already routes the whole `134060...134095` band to
`.storeRejected`[^editmodel-cocoa] — correct as a generic bucket, but too broad to
*degrade* on.

The **more specific signal** is the `NSUnderlyingException` string in the error's
`userInfo`. The verbatim dump from thread 723695 is:

```
Error Domain=NSCocoaErrorDomain Code=134092 "(null)" UserInfo={
  NSUnderlyingException=Unhandled error (NSCocoaErrorDomain, 134092) occurred during faulting and was thrown: Error Domain=NSCocoaErrorDomain Code=134092 "(null)",
  NSUnderlyingError=0x... {Error Domain=NSCocoaErrorDomain Code=134092 "(null)"}
}
```
[^thread723695-userinfo]

That `NSUnderlyingException` value — **"…occurred during faulting and was
thrown"** — is exactly the phrase in the GuessWho device-log
`objc_exception_throw` frame, so it is reliably present for *this* cause and
distinguishes a **faulting** failure from a plain validation/conflict 134092.

> **Verify on device before trusting it as a predicate.** I have NOT confirmed
> that `NSUnderlyingException` survives into the `NSError.userInfo` your
> `catch` block receives (vs. only appearing in the console `NSLog`). The adapter
> already dumps the full `userInfo` and the `NSUnderlyingError` chain at the
> `execute()` site[^adapter-logfailure] — the on-device test plan's **step 0** is
> to read that log and confirm which keys are actually present in the thrown
> error.

**Proposed predicate (only degrade when ALL hold), pending step-0 confirmation:**

1. We attempted a **Contacts write** (`update`) — i.e. we're in the adapter's
   `save(_:)` path, not a read.
2. Error is `NSCocoaErrorDomain`, code `134092`.
3. The error (or any `NSUnderlyingError` in its chain) carries an
   `NSUnderlyingException` / description containing **"during faulting"** (or, if
   step 0 shows it isn't in `userInfo`, fall back to gating on our own
   precondition instead — see #4).
4. **Strongest available gate, and the one I'd lean on:** *we already know the
   target contact has a non-empty Apple note.* We can't fetch the note
   (unentitled), **but** the daemon-side cause only fires for note-bearing
   contacts, and we can cheaply detect note-presence without reading the note —
   see [Detecting note presence without the entitlement](#detecting-note-presence-without-the-entitlement).
   If we only degrade for *contacts we independently know carry a note*, we will
   not over-catch unrelated 134092s on note-free contacts.

The safest production predicate is **(1) ∧ (2) ∧ ((3) ∨ (4))**: a faulting 134092
on a write to a contact we know has a note. That is narrow enough to avoid
swallowing genuine store rejections (read-only account, validation, conflict),
which the brief explicitly worries about.

### Detecting note presence without the entitlement

You cannot fetch `note`, but you *can* tell whether one exists, which makes the
predicate precise:

- The 134092 fault is itself a proxy: it only fires for note-bearing contacts.
  Combined with (1)+(2)+(3) that is already specific.
- **Stronger and proactive:** GuessWho already does a read/modify/write round
  trip. After a *successful* save of a given contact, record (in sidecar) that
  this contact saves cleanly; after a faulting failure, record that it is
  note-blocked. On the next edit you can pre-empt the write entirely for known
  note-blocked contacts and degrade immediately, with no scary error. This turns
  a caught exception into a known per-contact capability flag.

> I have **not** verified an entitlement-free API that returns a boolean
> "has note" without faulting. Treat the fault-as-proxy + remembered-capability
> approach as the reliable path; do not assume a clean "hasNote" probe exists.

### What graceful-degrade actually buys you

Be precise with Adam about scope, because the brief's phrasing ("preserve the
edit in our own sidecar storage") implies more than the current model delivers:

- **What it cleanly delivers today:** no crash, no raw "Cocoa error 134092"
  alert, and GuessWho-owned data (notes/tags/links/favorites) is unaffected —
  those never round-trip through `CNSaveRequest` on the Apple contact's Core Data
  store in a way that re-indexes the note. The adopt-on-first-write that mints the
  `guesswho://` URL is itself a contact write, so **note-bearing contacts may
  fail to receive their GuessWho URL** — that is the real functional casualty and
  must be handled (e.g. retry/skip, keep sidecar keyed correctly). This needs its
  own verification.
- **What it does NOT deliver without new design:** writing an *Apple* field
  (phone, email, name) to a note-bearing contact. The sidecar does not currently
  mirror Apple fields, so "preserve the phone-number edit in sidecar" would mean
  *introducing a shadow-copy of Apple-owned fields* with its own
  last-writer-wins/source-of-truth rules and a reconciliation story for when the
  entitlement later lands and the write finally succeeds. That is a **separate
  design decision**, not a free consequence of catching the error. Flag it
  explicitly; don't let "graceful-degrade" paper over it.

My recommendation: implement graceful-degrade as **(a) precise detection + (b)
no-crash/no-scary-alert + (c) a plain-language, non-blocking notice that "this
change couldn't be saved to Contacts"** (the existing `.storeRejected` copy is
already honest and close[^editmodel-message]), and treat *mirroring Apple fields
into sidecar* as a deliberate follow-up only if product wants edits-to-Apple-fields
to survive at all before the entitlement ships.

---

## Why nobody can locally verify

- The bug reproduces **only** in distribution/TestFlight builds: their
  provisioning profile lacks the notes entitlement, and Apple's docs confirm the
  entitlement *"requires permission from Apple to use, and you can't publicly
  distribute your app until you have permission."*[^notedoc] Dev-signed builds get
  enough latitude that the daemon does not deny the note fault, so the crash does
  not appear. (Forum thread 723695 explicitly notes the failure shows in the
  *release binary*.)[^thread723695]
- Therefore neither the researcher nor any local tooling can confirm a fix.
  The deliverable is an evidenced *recommended* strategy plus the on-device test
  plan below, which **Adam must run on a distribution-signed build.**

---

## On-device test plan (distribution-signed build, current iOS 26.x / macOS 26.x)

Run on a TestFlight (or distribution-signed) build, which is the only context
that reproduces 134092. Use a real contact you control. Each step is
independent; record pass/fail and the full thrown `NSError` (domain, code,
`userInfo`, `NSUnderlyingError` chain) via the adapter's existing `execute()`-site
log.[^adapter-logfailure]

**Setup.** In Contacts.app, add a **non-empty note** to a test contact (e.g.
"test note"). Confirm the GuessWho build in use has **no** `com.apple.developer.contacts.notes`
entitlement (the distribution profile).

**Step A — Confirm the platform difference is real, not a confound (do this FIRST,
it gates the recommendation).** On the **iOS** device where the save "works," open
the *same* contact in Contacts.app and **verify the note text is actually present**
(not blank, not missing due to sync lag or living on an unsynced account). Then,
on a distribution-signed build, perform the *identical* note-bearing field edit on
**both** iOS and Mac Catalyst and record pass/fail for each. Outcomes:
- iOS contact **has** the note AND iOS save succeeds while Catalyst fails →
  **true platform difference**; proceed with platform-scoped degrade.
- iOS contact has **no/blank** note → confound; the "iOS works" result is
  meaningless and there is no proven platform difference. Re-test iOS with a
  genuinely note-bearing, synced contact.

**Step 0 — Capture the real thrown error (do this first, on Catalyst).**
Edit a normal field (e.g. add a phone number) on the note-bearing contact through
the current code path. Confirm it throws 134092, then **read the adapter log** and
record: is `NSUnderlyingException` present in `userInfo`? Does any
`NSUnderlyingError` carry the "during faulting" string? Is the
`"[api] Attempt to read notes by an unentitled app"` line in the OS log only, or
also in the `NSError`? *This decides whether predicate clause (3) is usable or we
must rely on clause (4).*

**Step 1 — Control.** Repeat the same phone-number edit on a contact **with no
note**. Expected: succeeds. (Confirms the edit itself is valid and the gating
factor is the note.)

**Step 2 — Candidate 1 (fresh minimal `CNMutableContact`).** Build a
`CNMutableContact`, set only the existing `identifier` and the one changed field,
`update()` + `execute()` on the note-bearing contact. Record pass/fail. *Expected
fail; this is the longshot.*

**Step 3 — Bonus (`shouldRefetchContacts = false`).** Same edit via the normal
`mutableCopy` path but with `saveRequest.shouldRefetchContacts = false`. Record
pass/fail. *Expected fail; zero-cost to confirm.*

**Step 4 — Candidate 4 (empty note).** On a `mutableCopy` where you *can* set
`note` (you'll need the key fetched, which itself may fail — note that), set
`note = ""` and save. Record whether it changes anything. *Expected: still fails
or itself throws on the note key.* (Mostly to close the loop on the forum hint.)

**Step 5 — Graceful-degrade predicate.** With the predicate from
[Detecting this error](#detecting-this-error-and-not-over-catching) implemented
behind a debug flag, confirm: (a) it catches Step 0's error and degrades quietly;
(b) it does **not** catch an artificially-induced *unrelated* save failure (e.g.
a validation error from a malformed field, or a read-only-account rejection if you
can stage one) — i.e. those still surface as a normal error. This is the
over-catch guard.

**Step 6 — Entitlement positive control (optional, when Adam has approval).**
With the entitlement added and a fresh provisioning profile, repeat Step 0.
Expected: succeeds. Confirms the entitlement is the true fix and the degrade path
can be retired/relaxed.

**Step 7 — Diagnose the Debug-vs-distribution lever (answers Adam's sub-question).**
Dump the *actually-signed* entitlements of both the Debug `.app` and the
distribution/TestFlight `.app` and diff them:

```sh
codesign -d --entitlements :- /path/to/Debug/GuessWho.app
codesign -d --entitlements :- /path/to/Distribution/GuessWho.app
```

Read the embedded profile too (`security cms -D -i .../embedded.mobileprovision`,
or `embedded.provisionprofile` on Catalyst). Interpret:
- If the **Debug** signature contains `com.apple.developer.contacts.notes` or any
  `com.apple.private.*contacts*` entitlement that the distribution signature
  lacks → the cause is **lever 2** (capability silently in Debug only); fixable by
  cleaning the project signing config.
- If both signatures are identical **except** Debug has `get-task-allow: true` →
  the cause is **lever 1** (debuggable/dev-signed processes run under relaxed
  note-fault enforcement); the only real fix is the entitlement, and graceful-
  degrade is the bridge.
This step is cheap, needs no contact edit, and definitively settles *which*
mechanism is in play — do it alongside step 0.

---

## Confidence + unverified-claim ledger

| Claim | Confidence | How I know / what's unverified |
| --- | --- | --- |
| No client-side unentitled update avoids 134092 | High | Absence across Apple docs + 4 forum threads + SO + plugin changelog; mechanism is daemon-side. Cannot prove a universal negative — flagged. |
| Cause is daemon `willSave` note re-index | High | GuessWho device stack (confirmed context) + Apple "contact may be modified when the save request is executing"[^update]. |
| Fresh minimal `CNMutableContact` won't help (cand. 1) | Medium-high | Mechanism + no positive report. NOT tested on a distribution build. |
| Non-unified backing card won't help / shouldn't be used (cand. 2/3) | Medium (mechanism) / High (architecture) | Where-note-lives is UNKNOWN from sources; the architectural ban is certain.[^identity-unified] |
| Empty note still triggers it (cand. 4) | Medium-high | Direct forum report (blank note).[^thread723695-blank] |
| vCard cannot update / can't bypass (cand. 4) | High | Apple docs: vCard is serialization only, not a store write.[^vcard] |
| Not fixed in any shipping OS (cand. 5) | Medium-high | Reports through macOS 14.5; none report a cure. No data on unreleased iOS/macOS 27. |
| `NSUnderlyingException` "during faulting" is a usable predicate signal | **Medium — VERIFY (step 0)** | Present in forum `userInfo` dump[^thread723695-userinfo]; NOT confirmed it reaches our `catch`'s `NSError.userInfo` on this build. |
| `shouldRefetchContacts=false` won't help | Low-medium | Mechanism only (it's a post-save refetch toggle).[^refetch] Cheap to test. |
| Current OS = iOS 26 / macOS 26 (Tahoe); 27 unshipped | High | Verified via web (2026-06-29).[^osnaming-wiki][^osnaming-apple] |
| Graceful-degrade preserves *Apple-field* edits | **Low — NOT a current capability** | Sidecar doesn't mirror Apple fields; that's a separate design change. |
| Debug works / TestFlight fails = `get-task-allow`/dev-signature relaxes the note gate (lever 1) | **Medium — INFERENCE, not documented** | No Apple sentence says the gate is skipped for dev signatures. Best-supported inference from get-task-allow/TCC sources + the reproduced asymmetry. Test step 7 settles which lever. |
| The Debug/distribution difference is *which profile signed it + its capabilities* | High | TN2415: entitlements transferred from the signing profile and must match the signature.[^tn2415] |
| Bug is Mac Catalyst-only; iOS unaffected | **Medium — field report, NOT yet confound-cleared** | Adam's same-binary/same-contact observation; mechanistically plausible (macOS sandbox+TCC stack). Gated on test step A (confirm iOS contact actually has the note). |
| iOS vs macOS Contacts privacy models genuinely differ | High | macOS-only sandbox addressbook entitlement[^addressbook-ent]; iOS is TCC-prompt-only.[^accessing-store] |
| Notes entitlement is macOS-only by documentation | **False** | Docs say iOS 13+ AND macOS 13+; any platform split is enforcement divergence, not documented.[^accessing-store-notes][^notedoc] |
| Removing the macOS addressbook entitlement would "fix" it | **False — would break Contacts access** | It's the sandbox grant for ALL contact access, not a notes sub-gate.[^addressbook-ent] |

---

## Citations

<!-- Apple documentation (external URLs) -->
[^update]: [Apple — CNSaveRequest.update(_:): "The contact to be updated must already exist… Note that the contact may be modified when the save request is executing."](https://developer.apple.com/documentation/contacts/cnsaverequest/update(_:)-3gaig)
[^saverequest]: [Apple — CNSaveRequest: update/delete of an absent object → recordDoesNotExist; "Do not access objects in the save request while that request is executing."](https://developer.apple.com/documentation/contacts/cnsaverequest)
[^mutablecontact]: [Apple — CNMutableContact: "You may modify only those properties whose values you fetched from the contacts database… you can modify only those properties for which a value exists."](https://developer.apple.com/documentation/contacts/cnmutablecontact)
[^notedoc]: [Apple — CNContact.note: "To fetch the note property in iOS 13 or later or macOS 13 or later, add the com.apple.developer.contacts.notes entitlement… you can't publicly distribute your app until you have permission to use it."](https://developer.apple.com/documentation/contacts/cncontact/note)
[^entitlementdoc]: [Apple — com.apple.developer.contacts.notes: "When your app tries to fetch notes without the entitlement, it receives an unauthorizedKeys error. Your app only needs the entitlement if it reads or writes notes."](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.contacts.notes)
[^addressbook-ent]: [Apple — Address book entitlement (com.apple.security.personal-information.addressbook): macOS-only ("Available on: macOS 10.7+"); grants App-Sandbox "read-write access to contacts in the user's address book." No iOS equivalent.](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.personal-information.addressbook)
[^accessing-store]: [Apple — Accessing the contact store: cross-platform Contacts access is gated by the TCC prompt + NSContactsUsageDescription (no iOS sandbox entitlement)](https://developer.apple.com/documentation/contacts/accessing-the-contact-store)
[^accessing-store-notes]: [Apple — Accessing the contact store, "Add entitlement to view or update notes": entitlement required "in iOS 13, macOS 13, or later" — i.e. BOTH platforms per the written contract](https://developer.apple.com/documentation/contacts/accessing-the-contact-store)
[^vcard]: [Apple — CNContactVCardSerialization: only data(with:) (to vCard) and contacts(with:) (from vCard); no store-write method](https://developer.apple.com/documentation/contacts/cncontactvcardserialization)
[^refetch]: [Apple — CNSaveRequest.shouldRefetchContacts: default true; "refetches added and updated contacts… Set to false to suppress the refetch behavior and reduce the save request's execution time." (iOS 15.4+/macOS 12.3+)](https://developer.apple.com/documentation/contacts/cnsaverequest/shouldrefetchcontacts)
[^coredataerrors]: [CoreDataErrors.h (iPhoneOS9.3 SDK) — 134092 has no named constant; brackets: NSPersistentStoreUnsupportedRequestTypeError=134091, NSPersistentStoreIncompatibleVersionHashError=134100](https://github.com/theos/sdks/blob/master/iPhoneOS9.3.sdk/System/Library/Frameworks/CoreData.framework/Headers/CoreDataErrors.h)

<!-- Apple Developer Forums / third party (external URLs) -->
[^thread723695]: [Apple Developer Forums thread 723695 — "NSCocoaErrorDomain Code=134092 When Saving Contact": OP excludes the note key, uses update(), still fails for contacts WITH a non-empty note; fails in the release binary; no workaround found; spans Jan 2023–Jun 2024](https://developer.apple.com/forums/thread/723695)
[^thread723695-blank]: [Apple Developer Forums thread 723695 — reporter nigelhamilton: "The contact actually has a blank note" yet still receives the warning](https://developer.apple.com/forums/thread/723695)
[^thread723695-userinfo]: [Apple Developer Forums thread 723695 — console dump: NSUnderlyingException="Unhandled error (NSCocoaErrorDomain, 134092) occurred during faulting and was thrown"; "[api] Attempt to read notes by an unentitled app"](https://developer.apple.com/forums/thread/723695)
[^thread723695-versions]: [Apple Developer Forums thread 723695 — latest dated post: await, Jun '24, macOS 14.5 (23F79); none report a fix](https://developer.apple.com/forums/thread/723695)
[^thread718743]: [Apple Developer Forums thread 718743 — daemon log "Attempt to write notes by a pre-Fall-2022 app"; ADD path; macOS Ventura 13.0, Oct 2022; resolved only by adding the entitlement](https://developer.apple.com/forums/thread/718743)
[^thread757133]: [Apple Developer Forums thread 757133 — "Contact Note Entitlement Disappearing": entitlement requires Apple approval per Team ID and a fresh provisioning profile](https://developer.apple.com/forums/thread/757133)
[^thread757133-debug]: [Apple Developer Forums thread 757133 — vizcosity, Jun '24: the Contact Notes capability "appears for a few seconds, then disappears when I move to a different tab and return. This does not happen for the 'Debug' configuration."](https://developer.apple.com/forums/thread/757133)
[^thread723695-debug]: [Apple Developer Forums thread 723695 — BillChen2k: "In debugging mode inside Xcode, the contact will still be updated… But if I execute the compiled release binary in terminal… The contact will not be updated."](https://developer.apple.com/forums/thread/723695)
[^thread723695-platform]: [Apple Developer Forums thread 723695 — nigelhamilton compares the same shared code on iOS vs macOS; the "[api] Attempt to read notes by an unentitled app" line is on "the console in the Mac"; iOS save ~0.005s vs macOS ~0.35s](https://developer.apple.com/forums/thread/723695)
[^catalyst-macos-model]: [Microsoft Learn Q&A (community answer, analogous Keychain case) — "Mac Catalyst requires additional considerations for entitlements and signing because it's essentially an iOS app running in a macOS environment with stricter sandbox (App Sandbox) enforcement." (NOT Apple-official; not Contacts-specific — pattern corroboration only.)](https://learn.microsoft.com/en-us/answers/questions/5578082/mac-catalyst-keychain-access-fails-with-missingent)
[^thread125408]: [Apple Developer Forums thread 125408 — Contact Note Field Access entitlement granted on request; requires a new provisioning profile](https://developer.apple.com/forums/thread/125408)
[^mbs]: [MBS FileMaker Plugin changelog (CNContactStore.Contacts), v10.1 — fixed READ/fetch functions to work without the notes entitlement (by not requesting the note key); does not address the save path](https://www.mbsplugins.eu/CNContactStoreContacts.shtml)

<!-- OS-version verification (external URLs) -->
[^osnaming-wiki]: [Wikipedia — macOS Tahoe: macOS 26, released 2025-09-15; latest 26.5.2 on 2026-06-29; succeeded by macOS Golden Gate (27) late 2026](https://en.wikipedia.org/wiki/MacOS_Tahoe)
[^osnaming-apple]: [Apple — macOS: "macOS 27 Golden Gate" announced (WWDC 2026, 2026-06-08), shipping later in 2026](https://www.apple.com/os/macos/)
[^osnaming-mr]: [MacRumors — macOS Tahoe 26.5.1 (2026-06-01), confirming 26.x is the current shipping line](https://www.macrumors.com/2026/06/01/apple-releases-macos-tahoe-26-5-1/)

<!-- Debug-vs-distribution signing mechanism (external URLs) -->
[^tn2415]: [Apple — TN2415 Entitlements Troubleshooting: "the entitlements corresponding to the app's enabled Capabilities/Services are transferred to the app's signature from the provisioning profile Xcode chose to sign the app"; the OS validates "that entitlements match across the app's signature and the app's embedded provisioning profile."](https://developer.apple.com/library/archive/technotes/tn2415/_index.html)
[^gettaskallow-doc]: [Apple — TN2415: "get-task-allow … determines whether Xcode's debugger can attach to the app." Only Development profiles whitelist it.](https://developer.apple.com/library/archive/technotes/tn2415/_index.html)
[^gettaskallow-afine]: [AFINE — "To Allow or Not to get-task-allow": get-task-allow "is intended for the development process"; "creates a bypass for the Hardened Runtime, and we do not even need root"; an injected process "can inherit all the trust you gave to the original app, so silently access the TCC-protected resources." (NB: describes injection-based bypass, not the daemon directly waiving the note gate.)](https://afine.com/to-allow-or-not-to-get-task-allow-that-is-the-question)

<!-- GuessWho source (relative paths, symbol-anchored) -->
[^adapter-keys]: [CNContactStoreAdapter — `keys` deliberately omits CNContactNoteKey (read-side mitigation; necessary but not sufficient for the save fault)](../../Sources/GuessWhoSync/CNContactStoreAdapter.swift:CNContactStoreAdapter.keys)
[^adapter-logfailure]: [CNContactStoreAdapter.logSaveFailure — dumps top-level error + full NSUnderlyingError chain + userInfo at the execute() site; use it for test step 0](../../Sources/GuessWhoSync/CNContactStoreAdapter.swift:CNContactStoreAdapter.logSaveFailure)
[^editmodel-cocoa]: [ContactEditModel.cocoaErrorCategory — routes NSCocoaErrorDomain 134060…134095 (incl. 134092) to .storeRejected without asserting a cause](../../Sources/GuessWhoSync/ContactEditModel.swift:ContactEditModel.cocoaErrorCategory)
[^editmodel-message]: [ContactEditModel.SaveErrorCategory.saveFailureMessage — .storeRejected copy: "This change to the contact couldn't be saved: …" (honest, plain-language, no Settings button)](../../Sources/GuessWhoSync/ContactEditModel.swift:ContactEditModel.SaveErrorCategory)
[^identity-unified]: [docs/contact-identity.md — package uses ONLY unified contacts (unifiedContact/unifiedContacts), never the non-unified contact(withIdentifier:); identity keyed on the unified localID](../contact-identity.md)
