import SwiftUI
import GuessWhoSync

struct TLSBatchImportCandidate: Identifiable {
    let id: Int
    let profile: LinkedInProfile
    let matchedContactID: ContactID?
    let matchedContactName: String?
    let ambiguousMatchCount: Int
    let rows: [LinkedInDiffRow]
    let loadExistingPhoto: () async -> UIImage?
}

struct TLSBatchImportSelection {
    let profile: LinkedInProfile
    let matchedContactID: ContactID?
    let fields: Set<LinkedInDiffRow.Field>
}

/// Reviews a multi-person TLS roster before any contacts are changed. Each
/// person gets the same field-level controls as a single-profile import, while
/// the arrows and counter make the large roster practical in one sheet.
struct TLSBatchImportView: View {
    let candidates: [TLSBatchImportCandidate]
    let skippedPersonCount: Int
    let omittedPhotoCount: Int
    let onImport: ([TLSBatchImportSelection]) async -> [String]
    let onCancel: () -> Void
    let onComplete: () -> Void

    @State private var index = 0
    @State private var included: Set<Int>
    @State private var selected: [Int: Set<LinkedInDiffRow.Field>]
    @State private var existingPhoto: UIImage?
    @State private var incomingPhoto: UIImage?
    @State private var isImporting = false
    @State private var importIssues: [String] = []
    @State private var showsFailureAlert = false

    init(
        candidates: [TLSBatchImportCandidate],
        skippedPersonCount: Int,
        omittedPhotoCount: Int,
        onImport: @escaping ([TLSBatchImportSelection]) async -> [String],
        onCancel: @escaping () -> Void,
        onComplete: @escaping () -> Void
    ) {
        self.candidates = candidates
        self.skippedPersonCount = skippedPersonCount
        self.omittedPhotoCount = omittedPhotoCount
        self.onImport = onImport
        self.onCancel = onCancel
        self.onComplete = onComplete
        _included = State(initialValue: Set(candidates.map(\.id)))
        _selected = State(initialValue: Dictionary(
            uniqueKeysWithValues: candidates.map { ($0.id, Set($0.rows.map(\.id))) }
        ))
    }

    var body: some View {
        NavigationStack {
            Group {
                if let candidate = currentCandidate {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            if skippedPersonCount > 0 {
                                skippedPeopleNotice
                            }
                            if omittedPhotoCount > 0 {
                                omittedPhotosNotice
                            }
                            reviewInstructions(candidate)
                            fieldGrid(candidate)
                            navigationControls
                        }
                        .padding(.bottom, 12)
                    }
                } else {
                    ContentUnavailableView(
                        "No People Found",
                        systemImage: "person.crop.circle.badge.questionmark",
                        description: Text("The TLS page did not contain any importable people.")
                    )
                }
            }
            .navigationTitle("Import People from TLS")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { onCancel() }
                        .keyboardShortcut(.cancelAction)
                        .disabled(isImporting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(importButtonTitle) { beginImport() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(isImporting || selectionsToImport.isEmpty)
                }
            }
            .overlay {
                if isImporting {
                    ZStack {
                        Color.black.opacity(0.18).ignoresSafeArea()
                        ProgressView("Importing \(selectionsToImport.count) people…")
                            .padding(24)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                    }
                }
            }
        }
        .task(id: index) {
            await loadPhotos()
        }
        .alert("Import Finished with Issues", isPresented: $showsFailureAlert) {
            Button("Done") { onComplete() }
        } message: {
            Text(importIssues.joined(separator: "\n"))
        }
    }

    private var currentCandidate: TLSBatchImportCandidate? {
        candidates.indices.contains(index) ? candidates[index] : nil
    }

    private var skippedPeopleNotice: some View {
        Label(
            skippedPersonCount == 1
                ? "1 roster entry was skipped because it has no name."
                : "\(skippedPersonCount) roster entries were skipped because they have no names.",
            systemImage: "exclamationmark.triangle.fill"
        )
        .font(.callout)
        .foregroundStyle(.orange)
        .padding(.horizontal)
        .padding(.top, 10)
    }

    private var omittedPhotosNotice: some View {
        Label(
            omittedPhotoCount == 1
                ? "1 photo was omitted because the roster was too large to transfer."
                : "\(omittedPhotoCount) photos were omitted because the roster was too large to transfer.",
            systemImage: "photo.badge.exclamationmark"
        )
        .font(.callout)
        .foregroundStyle(.orange)
        .padding(.horizontal)
        .padding(.top, skippedPersonCount > 0 ? 0 : 10)
    }

    private var importButtonTitle: String {
        let count = selectionsToImport.count
        return count == 1 ? "Import 1 Person" : "Import \(count) People"
    }

    private var selectionsToImport: [TLSBatchImportSelection] {
        candidates.compactMap { candidate in
            guard included.contains(candidate.id),
                  let fields = selected[candidate.id],
                  !fields.isEmpty else { return nil }
            return TLSBatchImportSelection(
                profile: candidate.profile,
                matchedContactID: candidate.matchedContactID,
                fields: fields
            )
        }
    }

    private func reviewInstructions(_ candidate: TLSBatchImportCandidate) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Review each person with the arrows. Turn off fields you don’t want to import, or skip a person entirely.")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack {
                Label(
                    candidateStatus(candidate),
                    systemImage: candidate.matchedContactID == nil
                        ? "person.crop.circle.badge.plus"
                        : "person.crop.circle.badge.checkmark"
                )
                .font(.callout.weight(.medium))
                Spacer()
                Toggle(
                    "Include",
                    isOn: Binding(
                        get: { included.contains(candidate.id) },
                        set: { include in
                            if include { included.insert(candidate.id) }
                            else { included.remove(candidate.id) }
                        }
                    )
                )
                .toggleStyle(.switch)
            }
        }
        .padding(.horizontal)
        .padding(.top, 10)
    }

    private func candidateStatus(_ candidate: TLSBatchImportCandidate) -> String {
        if let name = candidate.matchedContactName {
            return "Updates \(name)"
        }
        if candidate.ambiguousMatchCount > 1 {
            return "Creates a new contact — \(candidate.ambiguousMatchCount) existing contacts share this name"
        }
        return "Creates a new contact"
    }

    private func fieldGrid(_ candidate: TLSBatchImportCandidate) -> some View {
        Grid(alignment: .topLeading, horizontalSpacing: 16, verticalSpacing: 0) {
            GridRow {
                Color.clear.frame(width: 22, height: 1)
                columnHeader("Existing")
                columnHeader("TLS")
            }
            Divider().gridCellColumns(3)
            ForEach(candidate.rows) { row in
                fieldRow(row, candidateID: candidate.id)
                Divider().gridCellColumns(3)
            }
        }
        .padding(.horizontal)
        .opacity(included.contains(candidate.id) ? 1 : 0.45)
        .allowsHitTesting(included.contains(candidate.id) && !isImporting)
    }

    private func columnHeader(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 4)
    }

    @ViewBuilder
    private func fieldRow(_ row: LinkedInDiffRow, candidateID: Int) -> some View {
        let isOn = Binding(
            get: { selected[candidateID]?.contains(row.id) == true },
            set: { on in
                var fields = selected[candidateID] ?? []
                if on { fields.insert(row.id) } else { fields.remove(row.id) }
                selected[candidateID] = fields
            }
        )
        GridRow(alignment: .top) {
            Button {
                isOn.wrappedValue.toggle()
            } label: {
                Image(systemName: isOn.wrappedValue ? "checkmark.square.fill" : "square")
                    .font(.title3)
                    .foregroundStyle(isOn.wrappedValue ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .padding(.top, 8)

            fieldCell(
                label: row.label,
                value: row.existing,
                isExisting: true,
                isPhoto: row.isPhoto,
                photo: existingPhoto
            )
            fieldCell(
                label: row.label,
                value: row.incoming,
                isExisting: false,
                isPhoto: row.isPhoto,
                photo: incomingPhoto
            )
        }
        .opacity(row.changed ? 1 : 0.55)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func fieldCell(
        label: String,
        value: String?,
        isExisting: Bool,
        isPhoto: Bool,
        photo: UIImage?
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption2).foregroundStyle(.tertiary)
            if isPhoto {
                if let photo {
                    Image(uiImage: photo)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 64, height: 64)
                        .clipShape(Circle())
                } else {
                    Image(systemName: isExisting ? "person.crop.circle" : "person.crop.circle.badge.plus")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 64, height: 64)
                        .foregroundStyle(.tertiary)
                }
            } else if let value, !value.isEmpty {
                Text(value)
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .foregroundStyle(isExisting ? Color.secondary : Color.primary)
            } else {
                Text("—").font(.body).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var navigationControls: some View {
        HStack {
            Button {
                index -= 1
            } label: {
                Label("Previous", systemImage: "chevron.left")
            }
            .disabled(index == 0 || isImporting)

            Spacer()
            Text("\(index + 1) of \(candidates.count)")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer()

            Button {
                index += 1
            } label: {
                Label("Next", systemImage: "chevron.right")
                    .labelStyle(.titleAndIcon)
            }
            .disabled(index + 1 >= candidates.count || isImporting)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private func loadPhotos() async {
        existingPhoto = nil
        incomingPhoto = nil
        guard let candidate = currentCandidate else { return }

        async let existing = candidate.loadExistingPhoto()
        let photoPayload = candidate.profile.photo
        async let incoming: UIImage? = Task.detached(priority: .userInitiated) {
            photoPayload?.decodedData().flatMap { UIImage(data: $0) }
        }.value
        let (loadedExisting, loadedIncoming) = await (existing, incoming)
        guard currentCandidate?.id == candidate.id else { return }
        existingPhoto = loadedExisting
        incomingPhoto = loadedIncoming
    }

    private func beginImport() {
        let selections = selectionsToImport
        guard !selections.isEmpty else { return }
        isImporting = true
        Task {
            let issues = await onImport(selections)
            isImporting = false
            if issues.isEmpty {
                onComplete()
            } else {
                importIssues = issues
                showsFailureAlert = true
            }
        }
    }
}
