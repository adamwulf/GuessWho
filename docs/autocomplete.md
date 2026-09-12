# Text-field autocomplete

How a text field in the app offers suggestions while the user types, and how
to add it to another field.

## Opting a field in

Two lines: one on the field, one on the container.

```swift
// The field: pass the same binding the TextField edits, plus a closure that
// returns the WHOLE candidate pool. It is read once per focus session (when
// the field gains focus), so it may depend on other fields that can only
// change while this one is unfocused. The field's submit action goes in
// `onSubmit:` — NOT in `.onSubmit`, which the modifier scopes out (see
// Interaction, Return).
TextField("Company", text: $model.edited.organizationName)
    .focused($focus, equals: .organization)
    .autocomplete(text: $model.edited.organizationName, onSubmit: { focus = .department }) {
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
blanks, duplicates, and the exact typed value dropped; at most eight typed
matches (the whole-pool list a field opens on is uncapped).

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

- Focus opens the menu on the whole pool — every candidate but the field's
  current value, in the pool's order, uncapped — so tabbing into Company
  lists every organization, and tabbing on into Department lists that
  company's departments. Typing narrows it to the ranked matches; clearing
  the field lists everything again. A field with an empty pool (Department
  before Company is filled in) opens nothing.
- ↓ / ↑ move the highlight; ↑ past the first suggestion clears it.
- Return or Tab accepts the highlighted suggestion and keeps focus in the
  field. With nothing highlighted, Return runs the field's `onSubmit:` and
  Tab keeps its usual meaning (next field). Return is taken as the field's
  submit action, not as a key press: a `TextField` turns a hardware Return
  into a submit, so the modifier owns the submit (`onSubmit` + `submitScope`)
  and the caller's action moves into the `onSubmit:` parameter. An
  `.onSubmit` attached outside the modifier never fires.
- Escape closes the menu until the text changes again (or focus returns).
  With the menu already closed, Escape is left alone, so the editor's own
  Escape binding gets it: both editors bind Escape to Cancel
  (`.keyboardShortcut(.cancelAction)`), which asks "Discard changes?" when
  there is unsaved work. So one Escape closes the menu, a second cancels
  the edit behind that confirmation.
- Tapping a row accepts it. Losing focus closes the menu.
- The menu opens just below the field, or above it when the keyboard, a bar,
  or the host's bottom edge leaves no room. It follows the field as the list
  scrolls and is pinned inside the host's visible band, so a field right
  above the tab bar keeps its menu flipped up. It goes away only when the
  row leaves the list (its `onDisappear`), and comes back with it.

## How it works

`App/GuessWho/Autocomplete/`:

- `AutocompleteModifier` (the field half) owns the state: current
  suggestions, highlighted index, the text the menu was dismissed for, and
  the field's frame in `.global` space (kept fresh through
  `onGeometryChange`). ↓ / ↑ / Tab / Escape arrive through `onKeyPress`,
  which fires for a focused `TextField` on iOS, iPadOS, and Mac Catalyst; a
  handler returns `.ignored` whenever the menu isn't showing, so the
  field's normal key behavior — and the editor's Escape → Cancel — is
  untouched. Return arrives as the submit action. The whole-pool list (on
  focus, or for a blank field) comes from `TextSuggestionFilter.all`, the
  typed-narrowing list from `TextSuggestionFilter.suggestions`; the menu's
  rows are lazy so a pool of every contact costs only its visible rows.
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
