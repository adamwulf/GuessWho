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
    /// not step through a `List` / `Form`: on Mac Catalyst it leaves the
    /// form for the next control in the window, the list column's search
    /// field. Taking the key here keeps it in the form.
    ///
    /// On a field with `.autocomplete`, attach this AFTER that modifier: its
    /// own Tab handler (accept the highlighted suggestion) must see the key
    /// first, and it passes the key on when nothing is highlighted.
    func editorTabStop(_ focus: ContactEditorFocus) -> some View {
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
                focus.wrappedValue = next
                // The next field can be below the visible part of the form,
                // and a `List` builds a row only when it comes on screen, so
                // bring its row into view.
                withAnimation {
                    scrollProxy?.scrollTo(Self.row(of: next))
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
