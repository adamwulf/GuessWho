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
    /// affordance and flips to a checkmark to confirm the copy; because that
    /// glyph is persistent, the layout reserves a matching slot on the leading
    /// side so the text stays centered. On touch the tap is the affordance, so
    /// no glyph — and therefore no reserved width — is used; a success haptic
    /// confirms instead, matching the platform convention of a silent copy.
    ///
    /// The tap gesture and the long-press / right-click "Copy" menu share one
    /// `copy()`, so both write the pasteboard and announce "Copied" to
    /// VoiceOver. VoiceOver reads the line as a button whose hint says it
    /// copies, and its activation runs the same `copy()`.
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

/// Backs `View.copyOnTap`: wires the tap-to-copy gesture, the shared context
/// menu, and the VoiceOver semantics. The visible affordance is
/// platform-split — a hover glyph on Catalyst, a success haptic on touch — so
/// touch platforms reserve no layout width for an icon they never show.
private struct CopyOnTapModifier: ViewModifier {
    let value: String

    // Only the Catalyst affordance is stateful (hover + a timed checkmark).
    // Touch confirms with a haptic and holds no state, so these don't exist
    // there.
    #if targetEnvironment(macCatalyst)
    @State private var isHovering = false
    @State private var didCopy = false
    /// Bumped on every copy so a later confirmation can't clear an earlier one's
    /// checkmark early when the user taps repeatedly.
    @State private var confirmToken = 0
    #endif

    func body(content: Content) -> some View {
        affordance(content)
            .contentShape(Rectangle())
            .onTapGesture { copy() }
            // The long-press / right-click menu runs the SAME copy(), so it too
            // confirms via haptic/announcement instead of silently writing the
            // pasteboard.
            .contextMenu {
                Button {
                    copy()
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
            }
            // Collapse this line into one VoiceOver element and present it as a
            // button that says it copies; activation and the rotor both run
            // copy(). On Catalyst this also folds in the hidden decorative
            // glyphs; on touch the text is all there is.
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Copies to the clipboard")
            .accessibilityAction { copy() }
    }

    @ViewBuilder
    private func affordance(_ content: Content) -> some View {
        #if targetEnvironment(macCatalyst)
        // Mac: a copy glyph fades in on hover as the affordance and flips to a
        // checkmark right after a copy. The leading balancer reserves its width
        // on the far side so the text stays centered whether or not it shows.
        HStack(spacing: 4) {
            glyph
                .hidden()
                .accessibilityHidden(true)

            content

            glyph
                .opacity(isHovering || didCopy ? 1 : 0)
                .accessibilityHidden(true)
        }
        .onHover { isHovering = $0 }
        #else
        // Touch: the tap is the affordance. No glyph, so nothing to reserve
        // width for — the header text keeps the full column and its centering.
        content
        #endif
    }

    #if targetEnvironment(macCatalyst)
    /// Fixed-width so the leading balancer and the trailing affordance always
    /// match regardless of which symbol is showing (`doc.on.doc` vs `checkmark`).
    private var glyph: some View {
        Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(width: 14)
    }
    #endif

    private func copy() {
        UIPasteboard.general.string = value

        // Confirm the copy: an announcement for VoiceOver on every platform, a
        // success haptic on touch (Catalyst Macs have no haptics), and — only
        // on Mac, where the glyph is visible — a brief checkmark.
        UIAccessibility.post(notification: .announcement, argument: "Copied")
        #if !targetEnvironment(macCatalyst)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        #else
        confirmToken += 1
        let token = confirmToken
        withAnimation(.easeInOut(duration: 0.15)) { didCopy = true }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard token == confirmToken else { return }
            withAnimation(.easeInOut(duration: 0.2)) { didCopy = false }
        }
        #endif
    }
}
