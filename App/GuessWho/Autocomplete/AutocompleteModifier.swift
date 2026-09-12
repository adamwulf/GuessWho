import SwiftUI
import GuessWhoSync

extension View {
    /// Make a text field autocomplete.
    ///
    /// Attach to any `TextField` (after its own `.focused`, if any). While
    /// the field has focus and the user types, matches from `candidates` —
    /// narrowed by `TextSuggestionFilter` — appear in a floating menu just
    /// below (or, when there's no room, above) the field:
    ///
    /// - ↓ / ↑ move the highlight (↑ past the first clears it).
    /// - Return or Tab accepts the highlighted suggestion and keeps focus in
    ///   the field. With nothing highlighted, Return runs `onSubmit` and Tab
    ///   keeps its usual meaning (next field).
    /// - Escape toggles the menu. Open, it hides until the text changes (or
    ///   Escape again). Closed, it opens on the WHOLE pool — every candidate
    ///   but the field's current value, in the pool's order — so the user can
    ///   tab into an empty Company field and browse every organization.
    /// - Tapping a suggestion accepts it. Typing refilters.
    ///
    /// `onSubmit` stands in for `.onSubmit` on the field. A `TextField` turns
    /// the Return key into its submit action, and that is where a highlighted
    /// suggestion has to be accepted instead of submitting — so this modifier
    /// owns the field's submit (scoped with `submitScope`, so an `.onSubmit`
    /// attached outside it never fires) and runs `onSubmit` only when no
    /// suggestion is highlighted.
    ///
    /// `candidates` supplies the whole pool; filtering and ranking are
    /// shared. It is read once per focus session — on the first keystroke or
    /// Escape after the field gains focus — and reused until focus leaves, so
    /// a pool that walks and sorts every contact isn't rebuilt per keystroke.
    /// It may still depend on other fields (the Department field's candidates
    /// depend on the Company field): those can only change while THIS field
    /// is unfocused, and the next focus reads them fresh.
    ///
    /// The menu is drawn by the nearest ancestor `.autocompleteMenuHost()`
    /// (put one on the enclosing `Form` / `List`). Without a host the field
    /// is an ordinary text field.
    func autocomplete(
        text: Binding<String>,
        onSubmit: (() -> Void)? = nil,
        candidates: @escaping () -> [String]
    ) -> some View {
        modifier(AutocompleteModifier(text: text, onSubmit: onSubmit, candidates: candidates))
    }
}

struct AutocompleteModifier: ViewModifier {
    @Binding var text: String
    let onSubmit: (() -> Void)?
    let candidates: () -> [String]

    @Environment(AutocompleteSession.self) private var session: AutocompleteSession?
    @FocusState private var isFocused: Bool
    @State private var fieldID = UUID()
    @State private var suggestions: [String] = []
    @State private var highlightedIndex: Int?
    /// The text suggestions were dismissed for — by Escape, or by accepting
    /// one (the accepted value is then the text). The menu stays hidden while
    /// the text still equals this, and comes back on the next edit (or when
    /// Escape reopens it on the whole pool).
    @State private var dismissedText: String?
    /// The field's frame in `.global` space, kept current as the list scrolls.
    @State private var anchor: CGRect = .zero
    /// The candidate pool for the current focus session (see `autocomplete`'s
    /// note on `candidates`). Cleared whenever focus changes.
    @State private var cachedCandidates: [String]?

    private var isMenuVisible: Bool { isFocused && !suggestions.isEmpty }

    /// The highlighted row, when there is one to accept.
    private var highlightedSuggestionIndex: Int? {
        guard isMenuVisible, let index = highlightedIndex, suggestions.indices.contains(index) else {
            return nil
        }
        return index
    }

    func body(content: Content) -> some View {
        content
            .focused($isFocused)
            .onGeometryChange(for: CGRect.self) { proxy in
                proxy.frame(in: .global)
            } action: { frame in
                anchor = frame
                // Re-anchor the open menu as the list scrolls under it.
                if isMenuVisible { publish() }
            }
            .onChange(of: text) { _, newValue in
                if newValue != dismissedText { dismissedText = nil }
                refilter()
            }
            .onChange(of: isFocused) { _, focused in
                cachedCandidates = nil
                if !focused { hide() }
            }
            .onKeyPress(.downArrow) { moveHighlight(by: 1) }
            .onKeyPress(.upArrow) { moveHighlight(by: -1) }
            .onKeyPress(.tab) { acceptHighlighted() }
            .onKeyPress(.escape) { toggleMenu() }
            // Return reaches the field as its submit action, not as a key
            // press (see `autocomplete`'s note on `onSubmit`): take it here,
            // and stop it short of any `.onSubmit` outside this modifier.
            .onSubmit { submit() }
            .submitScope()
            // A List reports a row as gone once it scrolls out of the safe
            // area, and back once it returns — while the field's focus and
            // this state live on. Take the menu down with the row and put it
            // back when the row is back.
            .onAppear { if isMenuVisible { publish() } }
            .onDisappear { session?.dismiss(fieldID: fieldID) }
    }

    // MARK: - State transitions

    /// Recompute the suggestions for the current text. Suggestions only ever
    /// appear in response to typing in a focused field — never on focus alone,
    /// so tabbing through a filled-in form doesn't pop menus.
    private func refilter() {
        guard isFocused, text != dismissedText else {
            hide()
            return
        }
        suggestions = TextSuggestionFilter.suggestions(matching: text, in: pool())
        highlightedIndex = nil
        publish()
    }

    /// Escape: hide an open menu (until the text changes, or Escape again),
    /// or open a closed one on the whole pool.
    private func toggleMenu() -> KeyPress.Result {
        if isMenuVisible {
            dismissedText = text
            hide()
            return .handled
        }
        return showAll()
    }

    /// Open the menu on every candidate but the current text, in the pool's
    /// order. Ignored when the pool has nothing to offer, so Escape keeps its
    /// usual meaning there.
    private func showAll() -> KeyPress.Result {
        guard isFocused else { return .ignored }
        let all = TextSuggestionFilter.all(in: pool(), excluding: text)
        guard !all.isEmpty else { return .ignored }
        dismissedText = nil
        suggestions = all
        highlightedIndex = nil
        publish()
        return .handled
    }

    /// The candidate pool for this focus session, read on first use.
    private func pool() -> [String] {
        if let cachedCandidates { return cachedCandidates }
        let pool = candidates()
        cachedCandidates = pool
        return pool
    }

    private func hide() {
        suggestions = []
        highlightedIndex = nil
        publish()
    }

    private func moveHighlight(by delta: Int) -> KeyPress.Result {
        guard isMenuVisible else { return .ignored }
        let last = suggestions.count - 1
        switch (highlightedIndex, delta) {
        case (nil, let d) where d > 0:
            highlightedIndex = 0
        case (nil, _):
            highlightedIndex = last
        case (let current?, let d) where d > 0:
            highlightedIndex = min(current + 1, last)
        case (let current?, _):
            // ↑ past the first suggestion returns to the typed text.
            highlightedIndex = current == 0 ? nil : current - 1
        }
        publish()
        return .handled
    }

    /// Tab: accept the highlighted suggestion, else let Tab move focus.
    private func acceptHighlighted() -> KeyPress.Result {
        guard let index = highlightedSuggestionIndex else { return .ignored }
        accept(index)
        return .handled
    }

    /// Return, as the field's submit action: accept the highlighted
    /// suggestion, else hand the submit to the caller.
    private func submit() {
        if let index = highlightedSuggestionIndex {
            accept(index)
        } else {
            onSubmit?()
        }
    }

    /// Write the suggestion at `index` into the field and close the menu.
    /// Focus stays in the field.
    private func accept(_ index: Int) {
        guard suggestions.indices.contains(index) else { return }
        let value = suggestions[index]
        // Set the dismissal marker first: the text change below re-runs
        // `refilter`, which must see the accepted value as dismissed.
        dismissedText = value
        text = value
        hide()
    }

    /// Push the current state to the host — or clear it when there's nothing
    /// to show.
    private func publish() {
        guard let session else { return }
        if isMenuVisible {
            session.present(AutocompleteSession.Presentation(
                fieldID: fieldID,
                anchor: anchor,
                suggestions: suggestions,
                highlightedIndex: highlightedIndex,
                accept: { accept($0) }
            ))
        } else {
            session.dismiss(fieldID: fieldID)
        }
    }
}
