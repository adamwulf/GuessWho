import SwiftUI
import GuessWhoSync

/// Mail-style stacked detail panes for a multi-selection. Each selected contact
/// is still rendered by the real `ContactDetailView`; the stack is presentation
/// only, so it cannot drift into a second contact-detail implementation.
struct ContactDetailStackView: View {
    let ids: [ContactID]

    /// Sheets deeper than this collapse onto the last visible sheet — Mail
    /// shows a few page edges, not a staircase.
    private static let maxVisibleSheets = 3

    /// How far a sheet's corners may poke out past the front card, in points.
    /// Deeper sheets poke out further so each page edge stays visible.
    private static func peek(atDepth depth: Int) -> CGFloat {
        depth == 0 ? 0 : 4 + CGFloat(depth) * 4
    }

    /// Mail's pile is rotation, not translation: every sheet shares the front
    /// card's center and tilts by a fraction of a degree, alternating sides.
    /// The angle is derived from the sheet size so corners overhang by a fixed
    /// point amount — a fixed angle would displace corners proportionally to
    /// the pane, either vanishing on a phone or escaping the padding on a
    /// large Catalyst window.
    private static func rotation(atDepth depth: Int, sheetSize: CGSize) -> Angle {
        let halfLongSide = max(sheetSize.width, sheetSize.height) / 2
        guard depth > 0, halfLongSide > 0 else { return .zero }
        let side: Double = depth.isMultiple(of: 2) ? -1 : 1
        return .radians(side * Double(peek(atDepth: depth) / halfLongSide))
    }

    var body: some View {
        let visibleSheets = min(max(ids.count - 1, 0), Self.maxVisibleSheets)
        let inset = 12 + Self.peek(atDepth: visibleSheets)
        GeometryReader { proxy in
            let sheetSize = CGSize(
                width: max(proxy.size.width - inset * 2, 0),
                height: max(proxy.size.height - inset * 2, 0)
            )
            ZStack {
                ForEach(Array(ids.prefix(Self.maxVisibleSheets + 1).enumerated()), id: \.element) { index, id in
                    Group {
                        if index == 0 {
                            // Only the visible card owns a live detail view. Hidden
                            // details would stamp every selected contact as viewed,
                            // mint identities, and contribute competing toolbars.
                            ContactDetailView(id: id)
                        } else {
                            Color(uiColor: .systemBackground)
                        }
                    }
                        .background(Color(uiColor: .systemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(Color.secondary.opacity(0.22), lineWidth: 1)
                        }
                        .shadow(color: .black.opacity(0.13), radius: 8, y: 3)
                        .rotationEffect(Self.rotation(atDepth: index, sheetSize: sheetSize))
                        .zIndex(Double(-index))
                        .allowsHitTesting(index == 0)
                        .accessibilityHidden(index != 0)
                }
            }
            .padding(inset)
        }
        .background(Color(uiColor: .secondarySystemBackground))
        .navigationTitle("\(ids.count) Contacts Selected")
    }
}
