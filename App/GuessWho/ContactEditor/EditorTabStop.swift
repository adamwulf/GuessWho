import SwiftUI
import GuessWhoSync

/// One stop of the contact editor's Tab order: the value each text field
/// of the editor binds to `ContactEditorFocus` with.
///
/// The contact's own fields are `.field`. The other cases are the text
/// fields the inline editor (`ContactDetailView`) shows after them: custom
/// fields and dated notes. Those save on their own, outside
/// `ContactEditModel`, so they are named here and not in the package's
/// `Field`. A custom field or a note is named by its id, not by its
/// position, so adding or removing one never sends focus to another.
enum ContactEditorStop: Hashable {
    /// A text field of the contact's own fields (`ContactEditModel.Field`).
    case field(ContactEditModel.Field)
    /// The value field of the custom field with this id.
    case customField(UUID)
    /// The text field of the dated note with this id, while it is open for
    /// editing.
    case datedNote(UUID)
    /// The text field of the new dated note (shown by "Add Note").
    case newDatedNote
}

/// The editor-wide focus every text field of the contact editor binds to.
/// `ContactEditorSections` owns it and hands it to each row.
typealias ContactEditorFocus = FocusState<ContactEditorStop?>.Binding

extension EnvironmentValues {
    /// The contact editor's stops in tab order: `ContactEditModel.tabOrder`
    /// (each field as `.field`), then the host's trailing stops.
    /// `ContactEditorSections` sets it; empty outside the editor.
    @Entry var contactEditorTabOrder: [ContactEditorStop] = []

    /// Scrolls the list or form that holds the contact editor. Each editor
    /// host sets it with `contactEditorScrolling()`; nil without one.
    @Entry var contactEditorScrollProxy: ScrollViewProxy? = nil
}

extension View {
    /// Make Tab and Shift-Tab in this text field move to the next and the
    /// previous stop of the contact editor (`ContactEditModel.tabStop` over
    /// `contactEditorTabOrder`), wrapping at the ends.
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
    /// `ContactEditorSections` also puts it on every section of the form,
    /// for Tab from a control that is not a text field: no stop has focus
    /// then, so Tab goes to the first stop and Shift-Tab to the last.
    func editorTabStop(_ focus: ContactEditorFocus) -> some View {
        modifier(EditorTabStop(focus: focus))
    }

    /// Make this text field `stop` of the contact editor's tab order: bind
    /// it to the editor focus and take Tab / Shift-Tab (`editorTabStop`).
    /// For the text fields the inline editor shows after the contact's own
    /// fields (custom fields, dated notes); the host lists `stop` in
    /// `ContactEditorSections`' trailing stops.
    ///
    /// Those fields keep their own focus state too, which decides when they
    /// save (a custom field commits when it loses focus). A view can carry
    /// more than one `.focused`, and each binding follows the one keyboard
    /// focus, so moving the editor focus away by Tab is the same focus loss
    /// as a click elsewhere. The hand check verifies it: a custom field's
    /// value is saved after Tab away. A nil `focus` (the same field in read
    /// mode, outside the editor) leaves the text field as it is.
    @ViewBuilder
    func editorTabStop(_ stop: ContactEditorStop, focus: ContactEditorFocus?) -> some View {
        if let focus {
            focused(focus, equals: stop)
                .editorTabStop(focus)
        } else {
            self
        }
    }

    /// Name this view as the list row that holds `field`, so Tab can scroll
    /// it into view (`editorTabStop`). Put it on the row itself — the view a
    /// `List` row is made of — not on a view inside one.
    func editorRow(_ field: ContactEditModel.Field) -> some View {
        editorRow(.field(field))
    }

    /// Name this view as the list row that holds `stop`: `editorRow` for a
    /// trailing stop (a custom field or a dated note).
    func editorRow(_ stop: ContactEditorStop) -> some View {
        id(stop)
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
    let focus: ContactEditorFocus
    @Environment(\.contactEditorTabOrder) private var tabOrder
    @Environment(\.contactEditorScrollProxy) private var scrollProxy

    /// Shift-Tab can arrive as the back-tab character (U+0019) instead of
    /// Tab with Shift, as it does in AppKit; both mean "previous field".
    private static let backTab = KeyEquivalent("\u{19}")

    func body(content: Content) -> some View {
        content
            .onKeyPress(keys: [.tab, Self.backTab]) { press in
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
                // main-actor turn (the same pattern as
                // `ScrollToHighlightedEmailModifier`). This is a best-effort
                // deferral: one Task hop is not guaranteed to run after the
                // List's layout pass has built the row. The hand check
                // verifies it (Tab past the bottom edge, and the wraps).
                scrollProxy?.scrollTo(Self.row(of: next))
                Task { @MainActor in
                    focus.wrappedValue = next
                }
                return .handled
            }
    }

    /// The row that holds `stop`, as `editorRow` names it. An address is
    /// one row with five fields, named by its street. A label text field
    /// shares its entry's row, named by the value field; a date's row is
    /// named by its label field, its only stop. A trailing stop (a custom
    /// field or a dated note) names its own row.
    private static func row(of stop: ContactEditorStop) -> ContactEditorStop {
        guard case .field(let field) = stop else { return stop }
        switch field {
        case .city(let index), .state(let index), .postalCode(let index), .country(let index),
             .addressLabel(let index):
            return .field(.street(index))
        case .phoneLabel(let index):
            return .field(.phone(index))
        case .emailLabel(let index):
            return .field(.email(index))
        case .urlLabel(let index):
            return .field(.url(index))
        case .relationLabel(let index):
            return .field(.relation(index))
        default:
            return stop
        }
    }
}
