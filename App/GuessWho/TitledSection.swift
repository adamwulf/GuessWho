import SwiftUI
import UIKit

extension EnvironmentValues {
    /// When true, a `TitledSection` draws its title as the section's first row
    /// instead of as its header. Set it on a `List` whose style pins section
    /// headers (`.inset`, `.plain`); see `TitledSection` for why.
    @Entry var sectionTitlesAsRows = false
}

/// A list `Section` with a title, styled like every section title in the
/// contact detail and the contact editor. Use it in place of
/// `Section { … } header: { Text(title).centeredSectionHeader() }`.
///
/// By default the title is the section's header. In a list that sets
/// `\.sectionTitlesAsRows`, the title is instead the section's first row,
/// drawn to look the same as the header, so the list has no header to pin.
///
/// Why: on Mac Catalyst in macOS 27, a list style that pins section headers
/// extends the top scroll-edge blur down to cover the pinned header. While
/// the list is still replacing estimated row heights with measured ones (the
/// first scroll through a long contact), the blur's bottom edge stays at an
/// old content position. The blur then covers most of the pane, and it can
/// stay that tall after the user scrolls back to the top. Grouped list styles
/// do not pin headers and do not show the problem, and SwiftUI has no API to
/// stop a `List` from pinning its headers. A section without a header has
/// nothing to pin.
struct TitledSection<Content: View, Footer: View>: View {
    @Environment(\.sectionTitlesAsRows) private var titlesAsRows

    private let title: String
    private let content: Content
    private let footer: Footer

    init(
        _ title: String,
        @ViewBuilder content: () -> Content,
        @ViewBuilder footer: () -> Footer
    ) {
        self.title = title
        self.content = content()
        self.footer = footer()
    }

    var body: some View {
        if titlesAsRows {
            Section {
                SectionTitleRow(title: title)
                content
            } footer: {
                footer
            }
        } else {
            Section {
                content
            } header: {
                Text(title).centeredSectionHeader()
            } footer: {
                footer
            }
        }
    }
}

extension TitledSection where Footer == EmptyView {
    /// A titled section with no footer. An `EmptyView` footer adds no footer
    /// space: the layout is the same as a `Section` declared without one.
    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.init(title, content: content, footer: { EmptyView() })
    }
}

/// A section title drawn as a list row that looks the same as the section
/// header it replaces: same font, color, position, and height, with no
/// separator and no row background. Measured against the `.inset` list's
/// header on Mac Catalyst (macOS 27.2): the text and every row below it land
/// on the same pixels.
private struct SectionTitleRow: View {
    let title: String

    /// Read so the title follows a text-size change like the header does.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Text(title)
            // The header uses UIKit's headline font. SwiftUI's `.headline` is
            // the same face and size but draws about 3% wider.
            .font(Font(UIFont.preferredFont(
                forTextStyle: .headline,
                compatibleWith: UITraitCollection(
                    preferredContentSizeCategory: UIContentSizeCategory(dynamicTypeSize)
                )
            )))
            .foregroundStyle(Color(uiColor: .secondaryLabel))
            .centeredSectionHeader()
            // The header's own top and bottom margins. The default leading and
            // trailing row insets already line the text up with the header.
            .listRowInsets(.vertical, 10)
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .accessibilityAddTraits(.isHeader)
    }
}
