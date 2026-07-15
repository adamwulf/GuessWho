import SwiftUI
import UIKit

extension View {
    /// Attach a long-press (iOS/iPadOS) / right-click (Mac Catalyst) "Copy" menu
    /// that writes `value` to the system pasteboard. Used on the non-editable
    /// title text of the detail views — a contact's or organization's name and
    /// an event's title — so the user can grab that text without opening an
    /// editor or selecting it character by character.
    ///
    /// A no-op (plain text, no menu) when `value` is blank: there's nothing
    /// worth copying, and an empty header shouldn't sprout a menu.
    @ViewBuilder
    func copyableText(_ value: String) -> some View {
        if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            self
        } else {
            contextMenu {
                Button {
                    UIPasteboard.general.string = value
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
            }
        }
    }
}
