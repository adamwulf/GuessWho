import AppKit
import SwiftUI

/// The compose popover: one row per recipient. A known recipient shows a photo
/// (or initials), name, title, and organization; one the contact cache doesn't
/// know shows its address and a plain note.
///
/// Sized explicitly from the row count so the hosting controller can report an
/// exact preferred size to Mail's popover.
struct RecipientsView: View {
    let model: RecipientsModel

    private static let width: CGFloat = 320
    private static let rowHeight: CGFloat = 52
    private static let noticeHeight: CGFloat = 36
    private static let messageHeight: CGFloat = 72
    private static let verticalPadding: CGFloat = 6
    private static let maximumHeight: CGFloat = 420

    var body: some View {
        content.frame(width: Self.width, height: height)
    }

    @ViewBuilder
    private var content: some View {
        if model.status == .loading {
            ProgressView().controlSize(.small)
        } else if model.rows.isEmpty {
            Text("Add recipients to see who they are.")
                .foregroundStyle(.secondary)
                .padding(.horizontal)
        } else {
            VStack(spacing: 0) {
                if model.status == .contactsUnavailable {
                    Text("Contact details aren’t available right now.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: Self.noticeHeight)
                    Divider()
                }
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(model.rows) { row in
                            RecipientRowView(row: row)
                                .frame(height: Self.rowHeight)
                        }
                    }
                    .padding(.vertical, Self.verticalPadding)
                }
            }
        }
    }

    private var height: CGFloat {
        guard model.status != .loading, !model.rows.isEmpty else { return Self.messageHeight }
        let notice = model.status == .contactsUnavailable ? Self.noticeHeight + 1 : 0
        let list = CGFloat(model.rows.count) * Self.rowHeight + 2 * Self.verticalPadding
        return min(notice + list, Self.maximumHeight)
    }
}

private struct RecipientRowView: View {
    let row: RecipientsModel.Row

    var body: some View {
        HStack(spacing: 10) {
            RecipientAvatar(summary: row.summary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .help(row.address)
    }

    private var title: String {
        guard let name = row.summary?.displayName, !name.isEmpty else { return row.address }
        return name
    }

    private var subtitle: String {
        guard let summary = row.summary else { return "No contact details" }
        let details = [summary.jobTitle, summary.organization]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return details.isEmpty ? row.address : details.joined(separator: " · ")
    }
}

private struct RecipientAvatar: View {
    let summary: MailContactSummary?

    private static let size: CGFloat = 36

    var body: some View {
        Group {
            if let image = summary?.thumbnail.flatMap(NSImage.init(data:)) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else if let initials, !initials.isEmpty {
                Circle()
                    .fill(Color.accentColor.gradient)
                    .overlay {
                        Text(initials)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                    }
            } else {
                Circle()
                    .fill(Color.secondary.opacity(0.2))
                    .overlay {
                        Image(systemName: "person.fill")
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .frame(width: Self.size, height: Self.size)
        .clipShape(Circle())
    }

    /// First letters of the first and last words of the name, e.g. "Ada
    /// Lovelace" → "AL", "Prince" → "P".
    private var initials: String? {
        guard let summary else { return nil }
        let words = summary.displayName.split(whereSeparator: \.isWhitespace)
        let letters = [words.first, words.count > 1 ? words.last : nil]
            .compactMap { $0?.first }
        return String(letters).uppercased()
    }
}
