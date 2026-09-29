import AppKit
import SwiftUI

/// The compose popover. Its first page is one row per recipient: a known
/// recipient shows a photo (or initials), name, title, and organization; one
/// the contact cache doesn't know shows its address and a plain note. Clicking
/// a known recipient slides in a detail page with a Back button and, when the
/// contact has an ID, a GuessWho button that opens the contact in the app.
///
/// Sized explicitly (from the row count on the list, a fixed height on the
/// detail page) so the hosting controller can report an exact preferred size
/// to Mail's popover.
struct RecipientsView: View {
    let model: RecipientsModel

    /// The row whose detail page is showing; nil shows the list. Held by ID so
    /// a recipient edit that drops the row also returns to the list.
    @State private var selectedRowID: String?

    static let width: CGFloat = 320
    static let rowHeight: CGFloat = 52
    static let noticeHeight: CGFloat = 36
    static let messageHeight: CGFloat = 72
    static let verticalPadding: CGFloat = 6
    static let maximumHeight: CGFloat = 420
    static let detailHeight: CGFloat = 380

    var body: some View {
        ZStack {
            if let row = selectedRow, let summary = row.summary {
                RecipientDetailView(summary: summary, onBack: { selectedRowID = nil })
                    .transition(.move(edge: .trailing))
            } else {
                list.transition(.move(edge: .leading))
            }
        }
        .frame(width: Self.width, height: height)
        .clipped()
        .animation(.easeInOut(duration: 0.25), value: selectedRow?.id)
    }

    /// The selected row, only while it is still in the list and has details.
    private var selectedRow: RecipientsModel.Row? {
        guard let selectedRowID else { return nil }
        return model.rows.first { $0.id == selectedRowID && $0.summary != nil }
    }

    @ViewBuilder
    private var list: some View {
        if model.rows.isEmpty {
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
                            rowView(row)
                                .frame(height: Self.rowHeight)
                        }
                    }
                    .padding(.vertical, Self.verticalPadding)
                }
            }
        }
    }

    @ViewBuilder
    private func rowView(_ row: RecipientsModel.Row) -> some View {
        if row.summary == nil {
            RecipientRowView(row: row)
        } else {
            Button {
                selectedRowID = row.id
            } label: {
                RecipientRowView(row: row)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private var height: CGFloat {
        if selectedRow != nil { return Self.detailHeight }
        guard !model.rows.isEmpty else { return Self.messageHeight }
        let notice = model.status == .contactsUnavailable ? Self.noticeHeight + 1 : 0
        let list = CGFloat(model.rows.count) * Self.rowHeight + 2 * Self.verticalPadding
        return min(notice + list, Self.maximumHeight)
    }
}

private struct RecipientRowView: View {
    let row: RecipientsModel.Row

    var body: some View {
        HStack(spacing: 10) {
            RecipientAvatar(summary: row.summary, size: 36)
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
            if row.summary != nil {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
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

/// The detail page for one contact: a header bar (Back, and GuessWho when the
/// contact can be opened in the app), then their photo, name, work line, and
/// the emails, phone numbers, and birthday the cache holds.
private struct RecipientDetailView: View {
    let summary: MailContactSummary
    let onBack: () -> Void

    private static let headerHeight: CGFloat = 36

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    identity
                    valueSection("Email", values: summary.emailAddresses)
                    valueSection("Phone", values: summary.phoneNumbers)
                    if let birthday = summary.birthday {
                        valueSection("Birthday", values: [MailLabeledValue(label: "", value: birthday)])
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var header: some View {
        HStack {
            Button(action: onBack) {
                Label("Back", systemImage: "chevron.left")
            }
            .buttonStyle(.borderless)
            Spacer()
            if let contactID = summary.contactID {
                Button("GuessWho") {
                    GuessWhoAppLink.open(contactID: contactID)
                }
                .buttonStyle(.borderless)
                .help("Open in GuessWho")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: Self.headerHeight)
    }

    private var identity: some View {
        HStack(spacing: 12) {
            RecipientAvatar(summary: summary, size: 56)
            VStack(alignment: .leading, spacing: 2) {
                Text(summary.displayName)
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)
                ForEach(workLines, id: \.self) { line in
                    Text(line)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
    }

    private var workLines: [String] {
        [summary.jobTitle, summary.organization]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    @ViewBuilder
    private func valueSection(_ title: String, values: [MailLabeledValue]) -> some View {
        if !values.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                ForEach(Array(values.enumerated()), id: \.offset) { _, entry in
                    VStack(alignment: .leading, spacing: 0) {
                        if !entry.label.isEmpty {
                            Text(entry.label)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text(entry.value)
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }
}

private struct RecipientAvatar: View {
    let summary: MailContactSummary?
    let size: CGFloat

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
                            .font(.system(size: size * 0.39, weight: .semibold))
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
        .frame(width: size, height: size)
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
