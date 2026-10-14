#if targetEnvironment(macCatalyst)
import UIKit
import GuessWhoLogging

/// Asks "Discard changes?" before the Mac's detail column throws away a
/// contact editor with unsaved changes.
///
/// The detail column REPLACES its card on every list, sidebar and wake
/// selection, which used to drop the editor's typed changes without a word.
/// Every one of those navigations runs through `perform`: with nothing
/// unsaved it runs at once, exactly as before; otherwise the user is asked
/// first, with the editor's own Cancel question and buttons. Discard drops
/// the changes as Cancel does and then navigates; Keep Editing cancels the
/// navigation and has the scene put the list and sidebar selection back.
///
/// One per scene, since each window has its own detail column. The scene
/// supplies how to find the editor, where to present, and how to put the
/// selection back.
@MainActor
final class DetailReplacementGate {
    private static let log = GuessWhoLog.logger("app.unsaved-edits")

    private let editorWithUnsavedChanges: () -> ContactEditorHandle?
    private let present: (UIViewController) -> Bool
    private let keepEditing: () -> Void

    /// The navigation waiting for the answer. A newer request while the
    /// question is up replaces it, so there is only ever one question and the
    /// latest click wins (a click on a multi-selection list can report twice:
    /// once for the row it deselects, once for the row it selects).
    private var pending: (() -> Void)?
    /// The question on screen. Weak, so one that UIKit never showed doesn't
    /// hold every later navigation back.
    private weak var question: UIAlertController?
    /// True while a navigation runs. A navigation can select a list or
    /// sidebar row on its way (the Mail path selects People), and the request
    /// that selection makes is part of the same navigation, so it goes
    /// straight through rather than asking again.
    private var isNavigating = false

    /// - Parameters:
    ///   - editorWithUnsavedChanges: the editor in the detail column with
    ///     unsaved changes, if any.
    ///   - present: presents the question; returns false when nothing could
    ///     present it.
    ///   - keepEditing: puts the list and sidebar selection back after a
    ///     navigation is cancelled.
    init(
        editorWithUnsavedChanges: @escaping () -> ContactEditorHandle?,
        present: @escaping (UIViewController) -> Bool,
        keepEditing: @escaping () -> Void
    ) {
        self.editorWithUnsavedChanges = editorWithUnsavedChanges
        self.present = present
        self.keepEditing = keepEditing
    }

    /// Run `navigation` — anything that replaces or clears the detail
    /// column — now, or once the user has chosen Discard.
    func perform(_ navigation: @escaping () -> Void) {
        if isNavigating {
            navigation()
            return
        }
        if question != nil {
            Self.log.notice("question already up — newer navigation replaces the waiting one")
            pending = navigation
            return
        }
        guard let editor = editorWithUnsavedChanges() else {
            run(navigation)
            return
        }
        ask(editor: editor, navigation: navigation)
    }

    private func ask(editor: ContactEditorHandle, navigation: @escaping () -> Void) {
        // Same wording and buttons as the editor's own Cancel confirmation.
        let alert = UIAlertController(title: "Discard changes?", message: nil, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Discard Changes", style: .destructive) { [weak self, weak editor] _ in
            Self.log.notice("discard: continuing the navigation")
            editor?.discard()
            self?.runPending()
        })
        alert.addAction(UIAlertAction(title: "Keep Editing", style: .cancel) { [weak self] _ in
            Self.log.notice("keep editing: navigation cancelled")
            self?.cancelPending()
        })
        pending = navigation
        question = alert
        Self.log.notice("unsaved edits in the detail column — asking before replacing it")
        if !present(alert) {
            // Nowhere to ask: keep the edits rather than lose them.
            Self.log.error("no presenter for the discard question — navigation cancelled")
            cancelPending()
        }
    }

    // Both answers clear `question` themselves: the alert may still exist
    // while it animates away, and a request arriving then must be handled
    // on its own, not parked behind an answer already given.

    private func runPending() {
        question = nil
        guard let navigation = pending else { return }
        pending = nil
        run(navigation)
    }

    private func cancelPending() {
        question = nil
        pending = nil
        keepEditing()
    }

    private func run(_ navigation: () -> Void) {
        isNavigating = true
        defer { isNavigating = false }
        navigation()
    }
}
#endif
