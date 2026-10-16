import SwiftUI

extension EnvironmentValues {
    /// The line from a hosted `ContactDetailView` to the scene that shows it.
    /// nil where nothing asks — every card except the Mac's detail column.
    @Entry var contactEditorHandle: ContactEditorHandle? = nil
}

/// How a scene asks one `ContactDetailView` about its inline editor before it
/// throws that card away. The Mac's detail column REPLACES its card on every
/// list, sidebar and wake selection (`DetailReplacementGate`), so the scene
/// asks first whether the editor holds unsaved changes and, when the user
/// chooses Discard, has the editor drop them exactly as its Cancel does.
///
/// The scene makes one per hosted card, puts it in the card's environment and
/// keeps it on the hosting controller, so it only ever asks the cards that are
/// in its column. The card fills it in when editing begins (`attach`); until
/// then it reports no unsaved changes.
@MainActor
final class ContactEditorHandle {
    private var unsavedChanges: () -> Bool = { false }
    private var discardChanges: () -> Void = {}
    private let editingDidBegin: () -> Void

    /// `editingDidBegin` runs each time the card starts editing, so the scene
    /// can note the selection to put back if the user keeps editing.
    init(editingDidBegin: @escaping () -> Void = {}) {
        self.editingDidBegin = editingDidBegin
    }

    /// Whether leaving the card now would lose changes the user typed — the
    /// rule the editor's own Cancel asks "Discard changes?" by.
    var hasUnsavedChanges: Bool { unsavedChanges() }

    /// Leave edit mode without saving, as the editor's Cancel does. On a "+"
    /// card never saved, this deletes its blank record too, but leaves the
    /// card for the scene to replace (`NewContactCleanup.discard`).
    func discard() {
        discardChanges()
    }

    /// Called by the card when editing begins. The closures must not capture
    /// the card's `self`: the card holds this handle in its environment, so a
    /// closure over `self` would keep the handle and the card's state alive
    /// in a loop. Capture the card's state bindings instead.
    func attach(hasUnsavedChanges: @escaping () -> Bool, discard: @escaping () -> Void) {
        unsavedChanges = hasUnsavedChanges
        discardChanges = discard
        editingDidBegin()
    }
}
