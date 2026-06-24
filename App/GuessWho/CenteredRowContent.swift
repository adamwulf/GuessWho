import SwiftUI

/// Width clamp for the Mac Catalyst contact-detail column.
///
/// On Catalyst the contact-detail `List` stays full-bleed so its scroll view
/// (and scrollbar) reach the pane edges, while each row's *content* is clamped
/// to a centered column of this width. This is the look the old
/// `.frame(maxWidth: 560)` on the whole `List` produced, minus the inert
/// non-scrolling side gutters that clamp left outside the scroll view.
///
/// The clamp is applied per ROW (see `centeredRowContent()`), never per
/// `Section`: a `Section` is a structural list element, not a laid-out view, so
/// `.frame(maxWidth:)` on it does not reliably bound row width. Row-content is a
/// real view, so the frame is honored there.
enum ContactDetailLayout {
    /// Max width the detail content is clamped to on macCatalyst.
    static let maxContentWidth: CGFloat = 560
}

extension View {
    /// Pin a list row's content to a `ContactDetailLayout.maxContentWidth`-wide
    /// column and center that column in the full-width cell — keeping the row
    /// separators aligned to the same column. The content fills the column
    /// rather than collapsing to its intrinsic width, so short rows line up with
    /// tall ones instead of floating centered. `alignment` controls how the
    /// content sits inside the column: `.leading` (the default) for ordinary
    /// rows, `.center` for the centered header. Apply this to a ROW's content
    /// view (not to a `Section`). No-op off macCatalyst, where no width clamp
    /// ever applied.
    @ViewBuilder
    func centeredRowContent(alignment: Alignment = .leading) -> some View {
        #if targetEnvironment(macCatalyst)
        let maxWidth = ContactDetailLayout.maxContentWidth
        self
            // 1. Stretch the content to fill the available width (aligned per
            //    `alignment`) so a short row (e.g. "image available / no")
            //    occupies the full column instead of shrinking to its intrinsic
            //    width and getting centered. 2. Cap that fill at `maxWidth` → a
            //    genuine 560-wide block. 3. Center that block in the full cell.
            .frame(maxWidth: .infinity, alignment: alignment)
            .frame(maxWidth: maxWidth)
            .frame(maxWidth: .infinity)
            // Pull the separators in to the centered column so they don't run
            // the full pane width — matching the old clamped-card look.
            .alignmentGuide(.listRowSeparatorLeading) { dimensions in
                max(0, (dimensions.width - maxWidth) / 2)
            }
            .alignmentGuide(.listRowSeparatorTrailing) { dimensions in
                dimensions.width - max(0, (dimensions.width - maxWidth) / 2)
            }
        #else
        self
        #endif
    }

    /// Inset a `Section` header's text to the same centered column the rows use.
    /// A `List` renders section headers in its own chrome, outside the row body,
    /// so `centeredRowContent()` on the rows doesn't reach them — the header
    /// would otherwise hug the pane's left edge. Wrap the header view with this
    /// so "Recent Events", "Debug", etc. line up with their rows' leading edge.
    /// No-op off macCatalyst.
    @ViewBuilder
    func centeredSectionHeader() -> some View {
        #if targetEnvironment(macCatalyst)
        let maxWidth = ContactDetailLayout.maxContentWidth
        self
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(maxWidth: maxWidth)
            .frame(maxWidth: .infinity)
        #else
        self
        #endif
    }
}
