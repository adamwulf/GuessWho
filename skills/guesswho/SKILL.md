---
name: guesswho
description: >-
  Read and write GuessWho contacts, events, and related data from the terminal
  with the `guesswho` command. Use this skill when you must find a contact, add
  or change a contact, read or write notes, custom fields, tags, groups, events,
  Maps guides and places, links between records, or favorites. GuessWho keeps a
  personal contact book plus private notes on top of the system Contacts and
  Calendar. All data stays on the local device.
---

# GuessWho CLI

`guesswho` is a terminal command that reads and writes the data in the
GuessWho app. GuessWho holds contacts and events. It also holds private
GuessWho data on top of them: dated notes, custom fields, tags, groups, links,
and favorites. All data stays on the device. Nothing goes to a network.

## Before you start

Two conditions must be true, or a command fails with exit code `69`:

1. The GuessWho app is open.
2. **Terminal Access** is on in the app Settings. This setting has three
   states: **Off**, **Read-only**, and **Read-write**. Reads need
   Read-only or higher. Writes need Read-write.

If a command reports that the app is not open or not ready, tell the user to
open GuessWho and set Terminal Access.

## Command shape

A command is a noun group and a hyphenated verb:

```
guesswho <noun> <verb> [ids…] [--flags…]
```

The noun groups are: `contacts`, `organizations`, `groups`, `events`,
`guides`, `places`, `links`, and `favorites`.

Rules:

- **Ids are positional.** Give them in the order the command shows.
- **Reads print JSON** to stdout, sorted by key.
- **`--limit`** (default 50, max 200) and **`--cursor`** page a long list.
- **stdout is data. stderr is messages.** Redirect stdout to keep clean data.
- **A field flag that you do not give stays unchanged.** An empty string
  (`--nickname ""`) clears that field.

Use `--help` on any command for the full option list:

```
guesswho --help
guesswho contacts --help
guesswho contacts update --help
```

## Common tasks

### Find a contact

```
guesswho contacts search "Ada Lovelace"
```

The search text must be at least two characters. Each result row has an `id`.
Use that `id` with the other commands.

To list contacts instead of search, use `contacts list`. You can narrow it:

```
guesswho contacts list --kind person
guesswho contacts list --favorites-only
guesswho contacts list --group-id <group-id>
```

### Read one contact

```
guesswho contacts get <contact-id>
```

This prints the full card.

### Add a contact

`contacts create` always makes a new contact. Give the fields as flags:

```
guesswho contacts create --given-name Ada --family-name Lovelace \
  --organization "Analytical Engine"
```

### Update a contact

`contacts update` changes only the scalar fields you give (a PATCH):

```
guesswho contacts update <contact-id> --job-title "Mathematician"
```

To change a phone number, email, URL, related name, or date, use the value
commands, one entry per call:

```
guesswho contacts add-value <contact-id> --field email --value ada@example.com --label work
guesswho contacts edit-value <contact-id> --field phone --current-value 555-0100 --new-value 555-0199
guesswho contacts delete-value <contact-id> --field email --value ada@example.com
```

Postal addresses, social profiles, and instant-message addresses have their
own `add-…`, `edit-…`, and `delete-…` commands, because they are structured
objects. Use `--help` for their fields.

### Delete a contact

```
guesswho contacts delete <contact-id>
```

This is the only command that asks the user to confirm. The app shows a dialog
with the contact name. The command waits for the answer. If the user cancels,
the command exits with code `10` and changes nothing.

## What data GuessWho holds

| Data | Command group | Notes |
|---|---|---|
| Contacts | `contacts` | Name, phones, emails, URLs, addresses, birthday, organization, and more. |
| Photos | `contacts get-photo` / `set-photo` | JPEG, PNG, GIF, HEIC, or WebP. Max 180 KiB. |
| Notes | `contacts add-note` / `list-notes` | Private, dated notes about a contact. These are GuessWho notes, **not** the Apple contact note. |
| Custom fields | `contacts set-custom-field` / `list-custom-fields` | Named values: text, multiline note, date, or checkbox. |
| Organizations | `organizations` | A contact whose kind is `organization`. Lists members and departments. |
| Groups | `groups`, `contacts list-groups` | Named sets of contacts. |
| Events | `events` | Calendar events, with tags you can add. |
| Guides & places | `guides`, `places` | Imported Apple Maps guides and their places. |
| Links | `links` | Connections between two records (contact, event, or place). |
| Favorites | `favorites`, `contacts set-favorite` | One ordered list of favorite contacts, events, groups, guides, and places. |

## Important limits

- **The Apple contact note is never available.** You cannot read, write, or
  search it through this command. GuessWho notes are a separate thing.
- **A contact `id` is a lookup key only.** No command can change it. Always
  get an `id` from a search or list first, then pass it to the next command.
- **A write needs Read-write access.** A read needs Read-only or higher.

## Exit codes

| Code | Meaning |
|---|---|
| `0` | Success. |
| `1` | The app returned an error. The message is on stderr. |
| `10` | The user declined a `contacts delete` confirmation. |
| `64` | A bad command line or argument. |
| `69` | The app is not open, not ready, or did not answer in time. |

## Get details

This skill shows the basics. For the full option list of any command, run it
with `--help`. Every noun group and verb has its own help text.
