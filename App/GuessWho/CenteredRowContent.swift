import SwiftUI

/// Width clamp for the Mac Catalyst contact-detail column.
///
/// On Catalyst the contact-detail `List` stays full-bleed so its scroll view
/// (and scrollbar) reach the pane edges, while each row's *content* is clamped
/// to a centered column of this width. This gives the centered-card look of a
/// `.frame(maxWidth: 560)` on the whole `List`, minus the inert non-scrolling
/// side gutters that clamp left outside the scroll view.
///
/// The clamp is applied per ROW (see `centeredRowContent()`), never per
/// `Section`: a `Section` is a structural list element, not a laid-out view, so
/// `.frame(maxWidth:)` on it does not reliably bound row width. Row-content is a
/// real view, so the frame is honored there.
enum ContactDetailLayout {
    /// Max width the detail content is clamped to on macCatalyst.
    static let maxContentWidth: CGFloat = 560

    /// A delete-only row in an active Catalyst `List` gets a leading edit
    /// accessory without a matching trailing reorder accessory. SwiftUI then
    /// centers the row in that asymmetrically reduced space, moving the
    /// centered content column about half an accessory width to the right.
    /// Pull delete-only rows back by that half-width so they stay aligned with
    /// ordinary rows and rows that have both delete and reorder accessories.
    static let deleteOnlyEditRowOffset: CGFloat = -12.5

    /// Extra space above a styled section header, on top of the list style's
    /// default — gives "Recent Events", "Debug", etc. room to breathe.
    static let sectionHeaderTopPadding: CGFloat = 12

    /// Space below a "more…" disclosure footer, separating it from the next
    /// section. A footer's breathing room belongs *below* it, not above —
    /// keeping the link tucked up against the section it discloses rather than
    /// floating in the gap toward the section below.
    static let sectionFooterBottomPadding: CGFloat = 12
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
    func centeredRowContent(
        alignment: Alignment = .leading,
        horizontalOffset: CGFloat = 0
    ) -> some View {
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
            .offset(x: horizontalOffset)
            // Pull the separators in to the centered column so they don't run
            // the full pane width — keeping them aligned to the clamped card.
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

    /// Style a `Section` header consistently across the contact detail: give it
    /// a little extra breathing room above (every platform), and — on Catalyst —
    /// inset it to the same centered column the rows use. A `List` renders
    /// section headers in its own chrome, outside the row body, so
    /// `centeredRowContent()` on the rows doesn't reach them; without this the
    /// header would hug the pane's left edge on Catalyst. Off Catalyst only the
    /// top padding applies (no width clamp there).
    @ViewBuilder
    func centeredSectionHeader() -> some View {
        let withTopMargin = self.padding(.top, ContactDetailLayout.sectionHeaderTopPadding)
        #if targetEnvironment(macCatalyst)
        let maxWidth = ContactDetailLayout.maxContentWidth
        withTopMargin
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(maxWidth: maxWidth)
            .frame(maxWidth: .infinity)
        #else
        withTopMargin
        #endif
    }

    /// Style a section *footer* — specifically the "more…" disclosure link — to
    /// the same centered column the rows use on Catalyst, but put its breathing
    /// room *below* (separating it from the next section) instead of above. A
    /// header wants the gap above it; a footer belongs to the section it follows,
    /// so the gap above is what makes the link read as floating between sections.
    /// Pulling the margin to the bottom tucks the link up under its own section.
    @ViewBuilder
    func centeredSectionFooter() -> some View {
        let withBottomMargin = self.padding(.bottom, ContactDetailLayout.sectionFooterBottomPadding)
        #if targetEnvironment(macCatalyst)
        let maxWidth = ContactDetailLayout.maxContentWidth
        withBottomMargin
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(maxWidth: maxWidth)
            .frame(maxWidth: .infinity)
        #else
        withBottomMargin
        #endif
    }
}
