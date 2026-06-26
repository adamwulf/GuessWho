import SwiftUI
import GuessWhoSync

/// The LinkedIn import confirm dialog: a per-field before/after diff with a
/// checkbox on each row (existing on the left, incoming from LinkedIn on the
/// right). Unchanged rows are de-emphasized. Confirm applies only the checked
/// rows; Cancel writes nothing. Saving itself is handled by the caller via the
/// `onConfirm` closure, which receives the set of selected fields.
struct LinkedInConfirmView: View {
    let contactID: ContactID
    let contactDisplayName: String
    let rows: [LinkedInDiffRow]
    /// Incoming photo bytes (decoded from the parsed `data:` URL), if any.
    let incomingPhoto: UIImage?
    /// Loads the existing contact photo (thumbnail). Async; nil if none.
    let loadExistingPhoto: () async -> UIImage?

    let onConfirm: (Set<LinkedInDiffRow.Field>) -> Void
    let onCancel: () -> Void

    @State private var selected: Set<LinkedInDiffRow.Field>
    @State private var existingPhoto: UIImage?

    init(
        contactID: ContactID,
        contactDisplayName: String,
        rows: [LinkedInDiffRow],
        incomingPhoto: UIImage?,
        loadExistingPhoto: @escaping () async -> UIImage?,
        onConfirm: @escaping (Set<LinkedInDiffRow.Field>) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.contactID = contactID
        self.contactDisplayName = contactDisplayName
        self.rows = rows
        self.incomingPhoto = incomingPhoto
        self.loadExistingPhoto = loadExistingPhoto
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        // All rows checked by default.
        _selected = State(initialValue: Set(rows.map(\.id)))
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(rows) { row in
                        rowView(row)
                    }
                } header: {
                    Text("Update “\(contactDisplayName)” from LinkedIn")
                } footer: {
                    Text("Turn off any field you don’t want to change. Existing values are on the left, LinkedIn values on the right.")
                }
            }
            .navigationTitle("LinkedIn")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { onCancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { onConfirm(selected) }
                        .disabled(selected.isEmpty)
                }
            }
        }
        .task {
            existingPhoto = await loadExistingPhoto()
        }
    }

    @ViewBuilder
    private func rowView(_ row: LinkedInDiffRow) -> some View {
        let isOn = Binding(
            get: { selected.contains(row.id) },
            set: { on in if on { selected.insert(row.id) } else { selected.remove(row.id) } }
        )
        HStack(alignment: .top, spacing: 12) {
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)

            VStack(alignment: .leading, spacing: 4) {
                Text(row.label)
                    .font(.caption).foregroundStyle(.secondary)

                if row.isPhoto {
                    HStack(spacing: 16) {
                        photoThumb(existingPhoto, placeholder: "person.crop.circle")
                        Image(systemName: "arrow.right").foregroundStyle(.secondary)
                        photoThumb(incomingPhoto, placeholder: "person.crop.circle.badge.plus")
                    }
                } else {
                    HStack(alignment: .top, spacing: 8) {
                        valueText(row.existing, isExisting: true)
                        Image(systemName: "arrow.right").foregroundStyle(.secondary)
                        valueText(row.incoming, isExisting: false)
                    }
                }
            }
        }
        // De-emphasize unchanged rows.
        .opacity(row.changed ? 1.0 : 0.55)
    }

    @ViewBuilder
    private func valueText(_ value: String?, isExisting: Bool) -> some View {
        if let value, !value.isEmpty {
            Text(value)
                .font(.body)
                .foregroundStyle(isExisting ? Color.secondary : Color.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(isExisting ? "—" : "")
                .font(.body).foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func photoThumb(_ image: UIImage?, placeholder: String) -> some View {
        if let image {
            Image(uiImage: image)
                .resizable().scaledToFill()
                .frame(width: 56, height: 56)
                .clipShape(Circle())
        } else {
            Image(systemName: placeholder)
                .resizable().scaledToFit()
                .frame(width: 56, height: 56)
                .foregroundStyle(.tertiary)
        }
    }
}
