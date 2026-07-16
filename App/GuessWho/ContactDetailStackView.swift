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
    /// How far each sheet drops below the one in front of it.
    private static let sheetDrop: CGFloat = 10

    /// Sheets must peek out from behind the front card in points, never via
    /// `scaleEffect`: a proportional scale displaces edges by a fraction of
    /// the pane size, which swamps any fixed offset in a full-size detail
    /// pane and hides the stack entirely. Alternating the horizontal side
    /// gives Mail's loose-pile look.
    private func sheetOffset(depth: Int) -> CGSize {
        guard depth > 0 else { return .zero }
        let side: CGFloat = depth.isMultiple(of: 2) ? -1 : 1
        return CGSize(
            width: side * (5 + CGFloat(depth) * 3),
            height: CGFloat(depth) * Self.sheetDrop
        )
    }

    var body: some View {
        let visibleSheets = min(max(ids.count - 1, 0), Self.maxVisibleSheets)
        let sidePeek = visibleSheets == 0 ? 0 : 5 + CGFloat(visibleSheets) * 3
        ZStack(alignment: .top) {
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
                    .offset(sheetOffset(depth: index))
                    .zIndex(Double(-index))
                    .allowsHitTesting(index == 0)
                    .accessibilityHidden(index != 0)
            }
        }
        .padding(.top, 12)
        .padding(.horizontal, 12 + sidePeek)
        .padding(.bottom, 12 + CGFloat(visibleSheets) * Self.sheetDrop)
        .background(Color(uiColor: .secondarySystemBackground))
        .navigationTitle("\(ids.count) Contacts Selected")
    }
}
