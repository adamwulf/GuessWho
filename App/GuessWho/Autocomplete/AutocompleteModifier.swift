import SwiftUI
import GuessWhoSync

extension View {
    /// Make a text field autocomplete.
    ///
    /// Attach to any `TextField` (after its own `.focused` / `.onSubmit`, if
    /// any). While the field has focus and the user types, matches from
    /// `candidates` — narrowed by `TextSuggestionFilter` — appear in a
    /// floating menu just below (or, when there's no room, above) the field:
    ///
    /// - ↓ / ↑ move the highlight (↑ past the first clears it).
    /// - Return or Tab accepts the highlighted suggestion; with nothing
    ///   highlighted they keep their usual meaning (submit / next field).
    /// - Escape hides the menu until the text changes again.
    /// - Tapping a suggestion accepts it. Typing refilters.
    ///
    /// `candidates` supplies the whole pool; filtering and ranking are
    /// shared. It is read once per focus session — on the first keystroke
    /// after the field gains focus — and reused until focus leaves, so a
    /// pool that walks and sorts every contact isn't rebuilt per keystroke.
    /// It may still depend on other fields (the Department field's candidates
    /// depend on the Company field): those can only change while THIS field
    /// is unfocused, and the next focus reads them fresh.
    ///
    /// The menu is drawn by the nearest ancestor `.autocompleteMenuHost()`
    /// (put one on the enclosing `Form` / `List`). Without a host the field
    /// is an ordinary text field.
    func autocomplete(
        text: Binding<String>,
        candidates: @escaping () -> [String]
    ) -> some View {
        modifier(AutocompleteModifier(text: text, candidates: candidates))
    }
}

struct AutocompleteModifier: ViewModifier {
    @Binding var text: String
    let candidates: () -> [String]

    @Environment(AutocompleteSession.self) private var session: AutocompleteSession?
    @FocusState private var isFocused: Bool
    @State private var fieldID = UUID()
    @State private var suggestions: [String] = []
    @State private var highlightedIndex: Int?
    /// The text suggestions were dismissed for — by Escape, or by accepting
    /// one (the accepted value is then the text). The menu stays hidden while
    /// the text still equals this, and comes back on the next edit.
    @State private var dismissedText: String?
    /// The field's frame in `.global` space, kept current as the list scrolls.
    @State private var anchor: CGRect = .zero
    /// The candidate pool for the current focus session (see `autocomplete`'s
    /// note on `candidates`). Cleared whenever focus changes.
    @State private var cachedCandidates: [String]?

    private var isMenuVisible: Bool { isFocused && !suggestions.isEmpty }

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
            .onKeyPress(.return) { acceptHighlighted() }
            .onKeyPress(.tab) { acceptHighlighted() }
            .onKeyPress(.escape) { dismissMenu() }
            .onDisappear { session?.dismiss(fieldID: fieldID) }
    }

    // MARK: - State transitions

    /// Recompute the suggestions for the current text. Suggestions only ever
    /// appear in response to typing in a focused field — never on focus alone,
    /// so tabbing through a filled-in form doesn't pop menus.
    private func refilter() {
        guard isFocused, text != dismissedText else {
            suggestions = []
            highlightedIndex = nil
            publish()
            return
        }
        let pool: [String]
        if let cachedCandidates {
            pool = cachedCandidates
        } else {
            pool = candidates()
            cachedCandidates = pool
        }
        suggestions = TextSuggestionFilter.suggestions(matching: text, in: pool)
        highlightedIndex = nil
        publish()
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

    private func acceptHighlighted() -> KeyPress.Result {
        guard isMenuVisible, let index = highlightedIndex, suggestions.indices.contains(index) else {
            return .ignored
        }
        accept(index)
        return .handled
    }

    private func dismissMenu() -> KeyPress.Result {
        guard isMenuVisible else { return .ignored }
        dismissedText = text
        hide()
        return .handled
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
