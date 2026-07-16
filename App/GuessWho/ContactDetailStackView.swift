import SwiftUI
import GuessWhoSync

/// Mail-style stacked detail panes for a multi-selection. Each selected contact
/// is still rendered by the real `ContactDetailView`; the stack is presentation
/// only, so it cannot drift into a second contact-detail implementation.
struct ContactDetailStackView: View {
    let ids: [ContactID]

    var body: some View {
        let visibleDepth = CGFloat(min(max(ids.count - 1, 0), 6))
        ZStack(alignment: .topLeading) {
            ForEach(Array(ids.enumerated()), id: \.element) { index, id in
                let depth = CGFloat(min(index, 6))
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
                    .scaleEffect(1 - depth * 0.018, anchor: .topLeading)
                    .offset(x: depth * 9, y: depth * 12)
                    .zIndex(Double(ids.count - index))
                    .allowsHitTesting(index == 0)
                    .accessibilityHidden(index != 0)
            }
        }
        .padding(.top, 12)
        .padding(.leading, 12)
        .padding(.trailing, 12 + visibleDepth * 9)
        .padding(.bottom, 12 + visibleDepth * 12)
        .background(Color(uiColor: .secondarySystemBackground))
        .navigationTitle("\(ids.count) Contacts Selected")
    }
}
