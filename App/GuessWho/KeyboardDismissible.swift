import SwiftUI
import UIKit

/// Keyboard ergonomics for SwiftUI forms/lists that host text input — the
/// SwiftUI counterpart to `UISearchController.installKeyboardDismissal` (see
/// `SearchKeyboardDismissal.swift`). On iPhone a `TextField` inside a sheet
/// otherwise traps the software keyboard: a vertical/multi-line field's return
/// key inserts a newline rather than dismissing, and there's no Cancel to fall
/// back on. This modifier gives such content the same two escapes we give the
/// search lists:
///
/// 1. Swipe: `.scrollDismissesKeyboard(.interactively)` pulls the keyboard down
///    with a drag over the scrollable content.
/// 2. Tap: a keyboard accessory bar with a right-aligned dismiss button, for
///    users who won't discover the swipe. Same `keyboard.chevron.compact.down`
///    glyph and "Hide Keyboard" label as the search bar's accessory.
///
/// The dismiss button resigns first responder globally
/// (`UIResponder.resignFirstResponder` via `sendAction`), mirroring the search
/// bar's `resignFirstResponder` — no `FocusState` to thread, so any hosting
/// form opts in with a single `.keyboardDismissible()`.
///
/// On Catalyst there's no software keyboard, so the accessory bar never appears
/// and the interactive dismiss is inert — safe to apply unconditionally.
private struct KeyboardDismissible: ViewModifier {
    func body(content: Content) -> some View {
        content
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button {
                        UIApplication.shared.sendAction(
                            #selector(UIResponder.resignFirstResponder),
                            to: nil,
                            from: nil,
                            for: nil
                        )
                    } label: {
                        Image(systemName: "keyboard.chevron.compact.down")
                    }
                    .accessibilityLabel("Hide Keyboard")
                }
            }
    }
}

extension View {
    /// Adds interactive swipe-to-dismiss and a right-aligned keyboard accessory
    /// dismiss button to scrollable content (a `Form`, `List`, or `ScrollView`)
    /// that hosts text input. See `KeyboardDismissible` for the rationale.
    func keyboardDismissible() -> some View {
        modifier(KeyboardDismissible())
    }
}
