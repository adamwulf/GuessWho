import SwiftUI

/// The one text field currently offering suggestions.
///
/// An `.autocomplete(text:onSubmit:candidates:)` field publishes its suggestion state
/// here; the enclosing `.autocompleteMenuHost()` overlay reads it and draws the
/// floating menu. Splitting the two lets the menu render in the HOST's
/// overlay — above every list row — instead of inside the field's own row,
/// where a `List`/`Form` cell would clip it or the next cell would paint over
/// it. The host installs one session in the environment; fields find it
/// there (an optional read, so a field outside any host is simply a plain
/// text field rather than a crash).
///
/// Only one field is ever active: a field that loses focus, runs out of
/// matches, or is dismissed clears its own presentation, and a presentation
/// from another field replaces whatever was showing.
@MainActor
@Observable
final class AutocompleteSession {
    struct Presentation {
        /// Identity of the publishing field, so a stale field can't clear a
        /// newer field's menu.
        let fieldID: UUID
        /// The field's frame in the `.global` SwiftUI coordinate space. The
        /// host converts it into its own overlay space.
        var anchor: CGRect
        var suggestions: [String]
        var highlightedIndex: Int?
        /// Accept the suggestion at an index — the field writes it into its
        /// binding and hides the menu. Called from the menu on tap.
        let accept: @MainActor (Int) -> Void
    }

    private(set) var presentation: Presentation?

    /// Show (or update) the menu for `presentation.fieldID`.
    func present(_ presentation: Presentation) {
        self.presentation = presentation
    }

    /// Hide the menu if `fieldID` is the field currently showing it.
    func dismiss(fieldID: UUID) {
        if presentation?.fieldID == fieldID {
            presentation = nil
        }
    }
}
