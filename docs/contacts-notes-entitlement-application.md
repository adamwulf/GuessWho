# Applying to Apple for the Contacts Notes entitlement

Plan for requesting `com.apple.developer.contacts.notes`, the special
(manually-approved) entitlement that lets GuessWho read/write the contact
**note** field. This is the clean fix for the TestFlight-only **134092** crash —
see [`research/contact-note-134092-strategy.md`](research/contact-note-134092-strategy.md).

## What matters

- **It's manually granted by Apple over email.** You can build/run for
  *development* with the key today, but you **cannot ship to TestFlight or the
  App Store** until it's granted and you regenerate the **distribution**
  provisioning profile. (TestFlight uses a distribution profile — that's why the
  crash is TestFlight-only.)
- **Request URL:** https://developer.apple.com/contact/request/contact-note-field
  (requires Developer login).
- **Request BEFORE submitting.** Submitting early neither triggers nor speeds the
  grant; it just gets a provisioning rejection. Start the clock now, in parallel.
- **Timeline is unpredictable:** Apple says 2–3 days; real reports run from a few
  days to **3+ weeks**. Email-only, **no status tracking**. Don't gate a release
  on it.
- **Granting bar is moderate.** No documented rejection wave for legitimate,
  user-facing note editing.

## How to frame it (what persuades)

Apple gates notes to prevent **harvesting/exfiltration**. Persuasive = *user's
own data, user-visible feature, stays in the user's control.*

- **Lead with:** GuessWho is a replacement Contacts app — the user views and
  edits the Notes field of their own contacts, exactly like Contacts.app.
  (First-party, user-initiated, symmetric read+write — strongest case.)
- **Secondary:** archive/restore of the user's contacts (incl. notes) to **their
  own iCloud**.
- **Trust signal:** no user-identifying info collected; notes never leave the
  user's iCloud / never sent to our servers. (Directly answers "are you
  harvesting?")
- **Omit:** the eventual CLI / MCP server. Not in the submitted app, and reads to
  a privacy reviewer like an off-device extraction pipe. Justify it later, once
  the entitlement is held.

## Suggested request text

> GuessWho is a contacts app that lets users view and edit their contacts,
> including the Notes field, just as Contacts.app does. We need read and write
> access to the contact note field to display and save what the user types. All
> data is stored in the user's own iCloud; we collect no user-identifying
> information and never transmit note contents to our servers. The app also lets
> users archive and restore their own contacts (including notes) to their
> personal iCloud.

## After it's granted

1. Regenerate the **distribution** provisioning profile with the entitlement
   enabled.
2. Add the key to `.entitlements` as Boolean `YES`; point `CODE_SIGN_ENTITLEMENTS`
   at it.
3. Re-download the profile. Gotcha: an `unauthorizedKeys` error even after grant
   means the `.entitlements` file isn't actually wired up (profile shows access
   but the build doesn't claim it).

**Fallback if the grant lags the release:** keep the interim mitigation — don't
`execute()` saves on note-bearing cards (see the 134092 doc).
