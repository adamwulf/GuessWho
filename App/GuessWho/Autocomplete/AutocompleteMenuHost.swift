import SwiftUI

extension View {
    /// Host the floating suggestion menu for every `.autocomplete(...)` field
    /// inside this view.
    ///
    /// Apply once, to the `Form` / `List` (or any ancestor) that contains the
    /// autocompleting fields. The menu renders in THIS view's overlay — above
    /// every row — so a list cell can never clip it or paint over it, and it
    /// follows the field as the list scrolls. Fields find the host through
    /// the environment; a field with no host behaves as a plain text field.
    func autocompleteMenuHost() -> some View {
        modifier(AutocompleteMenuHostModifier())
    }
}

private struct AutocompleteMenuHostModifier: ViewModifier {
    @State private var session = AutocompleteSession()

    func body(content: Content) -> some View {
        content
            .environment(session)
            .overlay { AutocompleteMenuOverlay(session: session) }
    }
}

/// Positions the menu next to the active field, inside the host's bounds.
private struct AutocompleteMenuOverlay: View {
    let session: AutocompleteSession

    var body: some View {
        GeometryReader { geometry in
            // The field reports its frame in `.global`; bring it into this
            // overlay's own space before placing the menu.
            //
            // This overlay's frame is ALREADY the visible band: a List/Form
            // lays its overlay out inside its safe-area-inset frame (measured
            // on iPhone: 660pt tall starting under the navigation bar, ending
            // above the tab bar, and the keyboard shrinks it the same way),
            // while the list's scroll content keeps running under the bars.
            // So the band to place within is simply `0...geometry.size`.
            // `geometry.safeAreaInsets` still reports the bars OUTSIDE this
            // frame (101 top / 83 bottom on that iPhone); subtracting them
            // here would count the bars twice and hide the menu for a field
            // sitting fully visible just above the tab bar — which is exactly
            // the bug an earlier version shipped. Don't use them.
            let container = geometry.frame(in: .global)
            if let presentation = session.presentation, !presentation.suggestions.isEmpty {
                let placement = AutocompleteMenuPlacement.compute(
                    anchor: presentation.anchor.offsetBy(dx: -container.minX, dy: -container.minY),
                    containerSize: geometry.size,
                    rowCount: presentation.suggestions.count
                )
                AutocompleteMenuView(
                    suggestions: presentation.suggestions,
                    highlightedIndex: presentation.highlightedIndex,
                    onSelect: presentation.accept
                )
                .frame(width: placement.frame.width, height: placement.frame.height)
                .offset(x: placement.frame.minX, y: placement.frame.minY)
            }
        }
    }
}

/// Pure geometry for the menu: where it goes and how big it is.
enum AutocompleteMenuPlacement {
    static let rowHeight: CGFloat = 36
    static let maxVisibleRows = 6
    /// Inner padding above the first and below the last row.
    static let verticalPadding: CGFloat = 6
    /// Gap between the field and the menu.
    static let gap: CGFloat = 4
    static let minWidth: CGFloat = 220
    /// Breathing room kept between the menu and the host's side edges.
    static let sideMargin: CGFloat = 8

    struct Placement: Equatable {
        var frame: CGRect
        /// True when the menu opens above the field because there was no
        /// room below it (keyboard, bottom of the host).
        var opensUpward: Bool
    }

    /// `anchor` is the field's frame in the host's coordinate space, and
    /// `containerSize` is the host's visible band — the overlay's own frame,
    /// which already stops at the bars and the keyboard (see the overlay).
    ///
    /// The menu opens below the field when it fits, else above it (so a
    /// field sitting right above the tab bar gets its menu flipped up), and
    /// below anyway when neither fits. It is then PINNED inside the band:
    /// never hidden on account of where the field is. A List stops updating
    /// a row's geometry once the row leaves the safe area, so a field that a
    /// scroll bounce has just brought back into view can still report a
    /// frame a few points beyond the band — hiding on that lag is what made
    /// the menu vanish for a fully visible field. Pinning keeps it right next
    /// to the field instead. A field that has actually left the list takes
    /// its menu with it through the row's `onDisappear`, not through geometry.
    static func compute(
        anchor: CGRect,
        containerSize: CGSize,
        rowCount: Int
    ) -> Placement {
        let visibleRows = max(1, min(rowCount, maxVisibleRows))
        let height = CGFloat(visibleRows) * rowHeight + verticalPadding * 2

        let maxWidth = max(minWidth, containerSize.width - sideMargin * 2)
        let width = min(max(anchor.width, minWidth), maxWidth)
        let maxX = max(sideMargin, containerSize.width - sideMargin - width)
        let x = min(max(anchor.minX, sideMargin), maxX)

        let belowY = anchor.maxY + gap
        let aboveY = anchor.minY - gap - height
        let fitsBelow = belowY + height <= containerSize.height
        let fitsAbove = aboveY >= 0
        let opensUpward = !fitsBelow && fitsAbove
        let wantedY = opensUpward ? aboveY : belowY
        let y = min(max(wantedY, 0), max(0, containerSize.height - height))

        return Placement(
            frame: CGRect(x: x, y: y, width: width, height: height),
            opensUpward: opensUpward
        )
    }
}

/// The menu itself: a scrolling column of tappable rows with one highlighted.
private struct AutocompleteMenuView: View {
    let suggestions: [String]
    let highlightedIndex: Int?
    let onSelect: (Int) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // Lazy: a field opens on the WHOLE pool — every organization,
                // or every contact for the Related field — and only the six
                // visible rows need building.
                LazyVStack(spacing: 0) {
                    ForEach(Array(suggestions.enumerated()), id: \.offset) { index, suggestion in
                        let isHighlighted = index == highlightedIndex
                        Button {
                            onSelect(index)
                        } label: {
                            Text(suggestion)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12)
                                .frame(height: AutocompleteMenuPlacement.rowHeight)
                                .foregroundStyle(isHighlighted ? Color.white : Color.primary)
                                .background(
                                    isHighlighted ? Color.accentColor : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                                )
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("autocomplete.suggestion.\(index)")
                        .accessibilityAddTraits(isHighlighted ? .isSelected : [])
                        .id(index)
                    }
                }
                .padding(.vertical, AutocompleteMenuPlacement.verticalPadding)
                .padding(.horizontal, 6)
            }
            .scrollBounceBehavior(.basedOnSize)
            .onChange(of: highlightedIndex) { _, index in
                if let index { proxy.scrollTo(index, anchor: nil) }
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.separator, lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("autocomplete.menu")
        .accessibilityLabel("Suggestions")
    }
}
