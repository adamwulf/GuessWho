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
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Turn off any field you don’t want to change. Existing values are on the left, LinkedIn values on the right.")
                        .font(.callout).foregroundStyle(.secondary)
                        .padding(.horizontal).padding(.top, 8).padding(.bottom, 4)

                    // Two aligned columns (Existing | LinkedIn), each data row
                    // prefixed by a checkbox. A Grid keeps the columns aligned
                    // across every row regardless of content width.
                    Grid(alignment: .topLeading, horizontalSpacing: 16, verticalSpacing: 0) {
                        GridRow {
                            Color.clear.frame(width: 22, height: 1) // checkbox column spacer
                            columnHeader("Existing")
                            columnHeader("LinkedIn")
                        }
                        Divider().gridCellColumns(3)
                        ForEach(rows) { row in
                            gridRow(row)
                            Divider().gridCellColumns(3)
                        }
                    }
                    .padding(.horizontal)
                }
                .padding(.bottom, 12)
            }
            .navigationTitle("Update “\(contactDisplayName)”")
            .navigationBarTitleDisplayMode(.inline)
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

    private func columnHeader(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 4)
    }

    @ViewBuilder
    private func gridRow(_ row: LinkedInDiffRow) -> some View {
        let isOn = Binding(
            get: { selected.contains(row.id) },
            set: { on in if on { selected.insert(row.id) } else { selected.remove(row.id) } }
        )
        GridRow(alignment: .top) {
            // Checkbox control. NOTE: SwiftUI's native `.toggleStyle(.checkbox)`
            // is unavailable unless the target is built with "Optimize Interface
            // for Mac" (Catalyst compiles against the iOS SDK, where `.checkbox`
            // doesn't exist). Until that idiom is enabled, render a custom
            // checkbox so we get a checkbox look on every config. Once
            // "Optimize for Mac" is on, this can become a plain Toggle (it'll be
            // a native Mac checkbox) or `.toggleStyle(.checkbox)`.
            Button {
                isOn.wrappedValue.toggle()
            } label: {
                Image(systemName: isOn.wrappedValue ? "checkmark.square.fill" : "square")
                    .font(.title3)
                    .foregroundStyle(isOn.wrappedValue ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .padding(.top, 8)

            cell(label: row.label, value: row.existing, isExisting: true,
                 isPhoto: row.isPhoto, photo: existingPhoto, placeholder: "person.crop.circle")
            cell(label: row.label, value: row.incoming, isExisting: false,
                 isPhoto: row.isPhoto, photo: incomingPhoto, placeholder: "person.crop.circle.badge.plus")
        }
        .opacity(row.changed ? 1.0 : 0.55) // de-emphasize unchanged rows
        .padding(.vertical, 8)
    }

    /// One column cell: the field label above the value (or a photo thumb).
    @ViewBuilder
    private func cell(
        label: String, value: String?, isExisting: Bool,
        isPhoto: Bool, photo: UIImage?, placeholder: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption2).foregroundStyle(.tertiary)
            if isPhoto {
                photoThumb(photo, placeholder: placeholder)
            } else if let value, !value.isEmpty {
                // Cap very tall values (About) and scroll inside the cell, but
                // allow a generous height so most text is visible without scroll.
                ScrollView { Text(value).font(.body).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(maxHeight: 320)
                    .foregroundStyle(isExisting ? Color.secondary : Color.primary)
            } else {
                Text("—").font(.body).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
