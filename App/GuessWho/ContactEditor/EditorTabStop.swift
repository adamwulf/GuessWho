import SwiftUI
import GuessWhoSync

/// The editor-wide focus every text field of the contact editor binds to.
/// `ContactEditorSections` owns it and hands it to each row.
typealias ContactEditorFocus = FocusState<ContactEditModel.Field?>.Binding

extension EnvironmentValues {
    /// The contact editor's text fields in tab order
    /// (`ContactEditModel.tabOrder`). `ContactEditorSections` sets it; empty
    /// outside the editor.
    @Entry var contactEditorTabOrder: [ContactEditModel.Field] = []

    /// Scrolls the list or form that holds the contact editor. Each editor
    /// host sets it with `contactEditorScrolling()`; nil without one.
    @Entry var contactEditorScrollProxy: ScrollViewProxy? = nil
}

extension View {
    /// Make Tab and Shift-Tab in this text field move to the next and the
    /// previous field of the contact editor (`ContactEditModel.tabStop`),
    /// wrapping at the ends.
    ///
    /// Without it, Tab is left to the system's keyboard focus, which does
    /// not step through a `List` / `Form`. In the inline editor on Mac
    /// Catalyst (`ContactDetailView` in the detail column) it left the form
    /// for the next control in the window, the list column's search field,
    /// and the unsaved edit could be lost. The new-contact sheet
    /// (`ContactEditView`) is modal, so Tab can't reach the list from it,
    /// but the system still doesn't step through its fields. Taking the key
    /// here keeps it in the form in both editors.
    ///
    /// On a field with `.autocomplete`, attach this AFTER that modifier: its
    /// own Tab handler (accept the highlighted suggestion) must see the key
    /// first, and it passes the key on when nothing is highlighted.
    ///
    /// A text field that is not a stop of the tab order (a custom field or a
    /// dated note of the inline edit) can use it too: none of the contact's
    /// fields has focus then, so Tab goes to the first field and Shift-Tab
    /// to the last. A nil `focus` (the same field outside the editor)
    /// leaves Tab alone.
    func editorTabStop(_ focus: ContactEditorFocus?) -> some View {
        modifier(EditorTabStop(focus: focus))
    }

    /// Name this view as the list row that holds `field`, so Tab can scroll
    /// it into view (`editorTabStop`). Put it on the row itself — the view a
    /// `List` row is made of — not on a view inside one.
    func editorRow(_ field: ContactEditModel.Field) -> some View {
        id(field)
    }

    /// Give the contact editor's text fields a way to scroll this list or
    /// form. Put it on the `List` / `Form` that hosts `ContactEditorSections`.
    func contactEditorScrolling() -> some View {
        ScrollViewReader { proxy in
            environment(\.contactEditorScrollProxy, proxy)
        }
    }
}

private struct EditorTabStop: ViewModifier {
    let focus: ContactEditorFocus?
    @Environment(\.contactEditorTabOrder) private var tabOrder
    @Environment(\.contactEditorScrollProxy) private var scrollProxy

    /// Shift-Tab can arrive as the back-tab character (U+0019) instead of
    /// Tab with Shift, as it does in AppKit; both mean "previous field".
    private static let backTab = KeyEquivalent("\u{19}")

    func body(content: Content) -> some View {
        content
            .onKeyPress(keys: [.tab, Self.backTab]) { press in
                guard let focus else { return .ignored }
                let backward = press.key == Self.backTab || press.modifiers.contains(.shift)
                guard let next = ContactEditModel.tabStop(
                    from: focus.wrappedValue,
                    backward: backward,
                    in: tabOrder
                ) else { return .ignored }
                // The next field can be outside the visible part of the form
                // (the next row below, or the first row after a wrap), and a
                // `List` builds a row only when it comes on screen: a field
                // with no row yet can't take focus. So scroll its row into
                // view first, with no animation, and move focus on a later
                // main-actor turn, once the List has had the chance to build
                // the row (the same pattern as
                // `ScrollToHighlightedEmailModifier`).
                scrollProxy?.scrollTo(Self.row(of: next))
                Task { @MainActor in
                    focus.wrappedValue = next
                }
                return .handled
            }
    }

    /// The row that holds `field`, as `editorRow` names it. An address is
    /// one row with five fields, named by its street. A label text field
    /// shares its entry's row, named by the value field; a date's row is
    /// named by its label field, its only stop.
    private static func row(of field: ContactEditModel.Field) -> ContactEditModel.Field {
        switch field {
        case .city(let index), .state(let index), .postalCode(let index), .country(let index),
             .addressLabel(let index):
            return .street(index)
        case .phoneLabel(let index):
            return .phone(index)
        case .emailLabel(let index):
            return .email(index)
        case .urlLabel(let index):
            return .url(index)
        case .relationLabel(let index):
            return .relation(index)
        default:
            return field
        }
    }
}
