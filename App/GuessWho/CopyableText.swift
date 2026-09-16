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

    /// Make a non-editable detail-header line copy itself to the pasteboard on a
    /// plain tap (iOS/iPadOS) or click (Mac Catalyst). Used on the contact/
    /// organization name and the subtitle (title · department · organization)
    /// so the text is one tap away without opening the editor.
    ///
    /// On Mac Catalyst a subtle copy glyph fades in on hover to advertise the
    /// affordance; on touch the tap is the affordance, so no persistent glyph is
    /// shown. Either way a brief checkmark confirms a successful copy. The
    /// long-press / right-click "Copy" menu from `copyableText` stays attached as
    /// a second, VoiceOver-reachable path.
    ///
    /// A no-op (plain, non-interactive text) when `value` is blank.
    @ViewBuilder
    func copyOnTap(_ value: String) -> some View {
        if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            self
        } else {
            modifier(CopyOnTapModifier(value: value))
        }
    }
}

/// Backs `View.copyOnTap`: lays the text between two equal-width glyph slots so
/// it stays centered whether or not the trailing copy glyph is showing, wires
/// the tap-to-copy gesture, and holds a short checkmark confirmation.
private struct CopyOnTapModifier: ViewModifier {
    let value: String

    @State private var isHovering = false
    @State private var didCopy = false
    /// Bumped on every copy so a later confirmation can't clear an earlier one's
    /// checkmark early when the user taps repeatedly.
    @State private var confirmToken = 0

    func body(content: Content) -> some View {
        HStack(spacing: 4) {
            // Leading balancer: reserves the glyph's width on the opposite side
            // so the text stays visually centered. Always invisible.
            glyph
                .hidden()
                .accessibilityHidden(true)

            content

            // Trailing glyph: the copy affordance. Revealed on hover (Mac) and
            // held briefly as a checkmark right after a copy so a touch tap gets
            // confirmation even without a pointer.
            glyph
                .opacity(isHovering || didCopy ? 1 : 0)
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
        .onTapGesture { copy() }
        #if targetEnvironment(macCatalyst)
        .onHover { isHovering = $0 }
        #endif
        // Keep the explicit long-press / right-click "Copy" menu as a second,
        // discoverable path (and the VoiceOver-reachable one).
        .copyableText(value)
    }

    /// Fixed-width so the leading balancer and the trailing affordance always
    /// match regardless of which symbol is showing (`doc.on.doc` vs `checkmark`).
    private var glyph: some View {
        Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(width: 14)
    }

    private func copy() {
        UIPasteboard.general.string = value
        confirmToken += 1
        let token = confirmToken
        withAnimation(.easeInOut(duration: 0.15)) { didCopy = true }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard token == confirmToken else { return }
            withAnimation(.easeInOut(duration: 0.2)) { didCopy = false }
        }
    }
}
