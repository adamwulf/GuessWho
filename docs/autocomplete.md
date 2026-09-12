# Text-field autocomplete

How a text field in the app offers suggestions while the user types, and how
to add it to another field.

## Opting a field in

Two lines: one on the field, one on the container.

```swift
// The field: pass the same binding the TextField edits, plus a closure that
// returns the WHOLE candidate pool. It is re-read on every keystroke, so it
// may depend on other fields.
TextField("Company", text: $model.edited.organizationName)
    .focused($focus, equals: .organization)
    .onSubmit { focus = .department }
    .autocomplete(text: $model.edited.organizationName) {
        repository?.organizationNameSuggestionCandidates() ?? []
    }

// The container: once, on the Form / List (or any ancestor) holding the
// fields. It draws the menu in its own overlay, above every row.
Form { … }
    .autocompleteMenuHost()
```

Filtering and ranking are shared (`TextSuggestionFilter` in `GuessWhoSync`),
so every field matches the same way: prefix hits first, then word-prefix
(`"wulf"` → `"Adam Wulf"`), then substring; case- and diacritic-insensitive;
blanks, duplicates, and the exact typed value dropped; at most eight.

Candidate lists for the contact editor live in
`Sources/GuessWhoSync/ContactsRepository+Suggestions.swift`:

| Field      | Candidates                                                                 |
|------------|----------------------------------------------------------------------------|
| Company    | Every organization name — records plus the company strings people carry.  |
| Department | Departments already used inside the Company named above (none until set). |
| Related    | Every contact's display name except the contact being edited.             |

Both editor surfaces host the menu: the new-contact sheet's `Form`
(`ContactEditView`) and the detail view's inline-edit `List`
(`ContactDetailView`). A field outside any host is a plain text field.

## Interaction

- Suggestions appear only in response to typing in a focused field — never on
  focus alone, so tabbing through a filled-in form pops no menus.
- ↓ / ↑ move the highlight; ↑ past the first suggestion clears it.
- Return or Tab accepts the highlighted suggestion and keeps focus in the
  field. With nothing highlighted they keep their usual meaning (submit /
  next field).
- Escape hides the menu until the text changes again.
- Tapping a row accepts it. Losing focus hides the menu.
- The menu opens just below the field, or above it when the keyboard, a bar,
  or the host's bottom edge leaves no room. It follows the field as the list
  scrolls and disappears while the field is scrolled under a bar.

## How it works

`App/GuessWho/Autocomplete/`:

- `AutocompleteModifier` (the field half) owns the state: current
  suggestions, highlighted index, the text the menu was dismissed for, and
  the field's frame in `.global` space (kept fresh through
  `onGeometryChange`). Hardware keys arrive through `onKeyPress`, which fires
  for a focused `TextField` on iOS, iPadOS, and Mac Catalyst; a handler
  returns `.ignored` whenever the menu isn't showing, so the field's normal
  key behavior is untouched.
- `AutocompleteSession` (an `@Observable` the host puts in the environment)
  carries the one active field's presentation — frame, suggestions,
  highlight, and an `accept` closure.
- `AutocompleteMenuHostModifier` (the host half) overlays the container with
  `AutocompleteMenuOverlay`, which converts the field's global frame into
  overlay space, runs `AutocompleteMenuPlacement.compute` (pure geometry:
  size, side clamping, below-or-above), and renders `AutocompleteMenuView`.

Why the menu lives in the host's overlay rather than in the field's row: a
`List` / `Form` cell would clip a menu that overflows it, or the next cell
would paint over it. The host's overlay sits above every row.

## Why not the alternatives

- **`inputAccessoryView` / `inputView`** — Mac Catalyst has no software
  keyboard, so an accessory bar never appears there; an iPad with a hardware
  keyboard hides it too. An arrow-key-driven highlight also doesn't map onto
  a horizontal chip strip.
- **SwiftUI `textInputSuggestions`** — macOS 15 only; unavailable on iOS and
  Catalyst.
- **`.popover`** — a presented popover takes key focus, so typing to refilter
  stops reaching the field.
- **Suggestion rows inside the section** — works, but shifts the layout on
  every keystroke and can't open above the field.
