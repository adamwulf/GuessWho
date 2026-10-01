import AppKit
import SwiftUI

/// The compose popover. Its first page is one row per recipient: a known
/// recipient shows a photo (or initials), name, title, and organization; one
/// the contact cache doesn't know shows the name Mail gave (if any) and its
/// address, and, when the cache was readable, an Add Contact button that opens
/// the app's new-contact editor filled in with them. Clicking a known
/// recipient slides in a detail page with a Back button and, when the contact
/// has an ID, a GuessWho button that opens the contact in the app.
///
/// Sized explicitly: the list from its row count, the detail page from its
/// measured content, both capped at `maximumHeight` and scrolling past it.
/// Each later size change goes to `onSizeChange` so the view controller can
/// resize Mail's popover.
struct RecipientsView: View {
    let model: RecipientsModel
    let onSizeChange: (CGSize) -> Void

    /// The row whose detail page is showing; nil shows the list. Held by ID so
    /// a recipient edit that drops the row also returns to the list.
    @State private var selectedRowID: String?
    /// The last detail page's full height, as it reported it, and the row it
    /// belongs to. Used only while that row is open, so opening another row
    /// keeps the list's height until its page reports. Kept, not cleared, on
    /// Back: reopening the same row during the Back slide-out reuses its
    /// outgoing page (same `.id`), which doesn't report again, so this stored
    /// height sizes it.
    @State private var detailHeight: (rowID: String, value: CGFloat)?

    static let width: CGFloat = 320
    static let rowHeight: CGFloat = 52
    static let noticeHeight: CGFloat = 36
    static let messageHeight: CGFloat = 72
    static let verticalPadding: CGFloat = 6
    static let maximumHeight: CGFloat = 420

    var body: some View {
        ZStack {
            if let row = selectedRow, let summary = row.summary {
                RecipientDetailView(
                    summary: summary,
                    onBack: { selectedRowID = nil },
                    onHeightChange: { detailHeight = (row.id, $0) }
                )
                // Without its own identity, a different row opened during the
                // Back slide-out reuses the outgoing page, whose unchanged
                // height is never reported again. (The same row still reuses
                // its page; the stored `detailHeight` covers that.)
                .id(row.id)
                .transition(.move(edge: .trailing))
            } else {
                list.transition(.move(edge: .leading))
            }
        }
        .frame(width: Self.width, height: height)
        .clipped()
        .animation(.easeInOut(duration: 0.25), value: selectedRow?.id)
        .onChange(of: height) { _, newHeight in
            onSizeChange(CGSize(width: Self.width, height: newHeight))
        }
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
            RecipientRowView(row: row, onAdd: addAction(for: row))
        } else {
            Button {
                selectedRowID = row.id
            } label: {
                RecipientRowView(row: row, onAdd: nil)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    /// Adds an unknown recipient, only when the cache was fully readable (so
    /// the person really is unknown, not just unreadable) and the token is a
    /// valid address.
    private func addAction(for row: RecipientsModel.Row) -> (() -> Void)? {
        guard model.status == .ready, row.summary == nil, let email = row.normalizedAddress else {
            return nil
        }
        let name = row.displayName
        return { GuessWhoAppLink.openNewContact(email: email, name: name) }
    }

    private var height: CGFloat {
        if let selectedRow, let detailHeight, detailHeight.rowID == selectedRow.id {
            return min(detailHeight.value, Self.maximumHeight)
        }
        return listHeight
    }

    private var listHeight: CGFloat {
        guard !model.rows.isEmpty else { return Self.messageHeight }
        let notice = model.status == .contactsUnavailable ? Self.noticeHeight + 1 : 0
        let list = CGFloat(model.rows.count) * Self.rowHeight + 2 * Self.verticalPadding
        return min(notice + list, Self.maximumHeight)
    }
}

private struct RecipientRowView: View {
    let row: RecipientsModel.Row
    /// Shows an Add Contact button at the row's end when set.
    let onAdd: (() -> Void)?

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
            } else if let onAdd {
                Button(action: onAdd) {
                    Image(systemName: "person.crop.circle.badge.plus")
                        .imageScale(.large)
                }
                .buttonStyle(.borderless)
                .help("Add Contact")
                .accessibilityLabel("Add Contact")
            }
        }
        .padding(.horizontal, 12)
        .help(row.address)
    }

    /// The contact's name; for an unknown recipient, the name Mail gave, or
    /// else the address.
    private var title: String {
        if let summary = row.summary {
            return summary.displayName.isEmpty ? row.address : summary.displayName
        }
        return row.displayName ?? row.address
    }

    private var subtitle: String {
        guard let summary = row.summary else {
            return row.displayName == nil ? "No contact details" : row.address
        }
        let details = [summary.jobTitle, summary.organization]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return details.isEmpty ? row.address : details.joined(separator: " · ")
    }
}

/// The detail page for one contact: a header bar (Back, and GuessWho when the
/// contact can be opened in the app), then their photo, name, work line, and
/// the emails, phone numbers, and birthday the cache holds. Reports its full
/// height (header, divider, and the scrolling content's natural height) to
/// `onHeightChange`; the content scrolls when `RecipientsView` caps that
/// height.
private struct RecipientDetailView: View {
    let summary: MailContactSummary
    let onBack: () -> Void
    let onHeightChange: (CGFloat) -> Void

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
                // Measured inside the scroll view, so the height is the
                // content's own and doesn't follow the popover's. The
                // divider is 1pt.
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight in
                    onHeightChange(Self.headerHeight + 1 + contentHeight)
                }
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
