import SwiftUI
import PhotosUI
import GuessWhoSync
import GuessWhoLogging

/// Every photo on a contact, current and previous: view one, make one current,
/// add one, or delete one for good. Presented as a sheet on every platform.
struct ContactPhotosView: View {
    private static let log = GuessWhoLog.logger("contact.photo")

    let repository: ContactsRepository
    let contactID: ContactID
    /// Called before a write, because one that fails partway can still leave a photo.
    let onWillChange: () -> Void
    /// Called after a change, to refresh whatever shows the current photo.
    let onDidChange: () async -> Void

    private struct AddPhotoRequest: Identifiable {
        let id = UUID()
        let photo: PickedPhoto
    }

    @Environment(\.dismiss) private var dismiss
    @State private var items: [ContactPhotoItem] = []
    @State private var hasLoaded = false
    /// The list has never loaded, and the last try failed.
    @State private var firstLoadFailed = false
    @State private var loadGeneration = 0
    @State private var isChanging = false
    @State private var viewerPhoto: FullscreenPhoto?
    @State private var photoToDelete: ContactPhotoItem?
    @State private var addRequest: AddPhotoRequest?
    @State private var presentingPhotoPicker = false
    @State private var photoPickerItem: PhotosPickerItem?
    @State private var photoSaveError: String?
    @State private var photoOpenError: String?
    /// The Mac file panel is modeless, so the sheet stays clickable behind it. Done would
    /// drop the file chosen later, and Add Photo would open a second panel.
    @State private var isFilePanelOpen = false

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("All Photos")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }.disabled(isChanging || isFilePanelOpen)
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button("Add Photo") { presentingPhotoPicker = true }.disabled(isChanging || isFilePanelOpen)
                    }
                }
        }
        .interactiveDismissDisabled(isChanging || isFilePanelOpen)
        .task(id: loadGeneration) { await reload() }
        // Also how a photo arriving from another device appears.
        .onReceive(NotificationCenter.default.publisher(for: .contactsRepositoryDidReload, object: repository)) { _ in
            loadGeneration += 1
        }
        .fullScreenCover(item: $viewerPhoto) { photo in
            ContactPhotoViewer(image: photo.image)
        }
        .sheet(item: $addRequest) { request in
            ContactPhotoCropEditor(image: request.photo.image, initialCrop: nil) { crop in
                onWillChange()
                try await repository.addContactPhoto(for: contactID, imageData: request.photo.data, crop: crop)
                await onDidChange()
                loadGeneration += 1
            }
        }
        .confirmationDialog(
            "Delete this photo?",
            isPresented: Binding(get: { photoToDelete != nil }, set: { if !$0 { photoToDelete = nil } }),
            titleVisibility: .visible,
            presenting: photoToDelete
        ) { item in
            Button("Delete Photo", role: .destructive) {
                Task { await change(operation: "delete") {
                    try await repository.deleteContactPhoto(for: contactID, photoID: item.id)
                } }
            }
            Button("Cancel", role: .cancel) {}
        } message: { item in
            Text(item.isCurrent
                ? "It will be removed from all your devices, and this contact will have no photo."
                : "It will be removed from all your devices.")
        }
        .alert(
            "Couldn’t Open Photo",
            isPresented: Binding(get: { photoOpenError != nil }, set: { if !$0 { photoOpenError = nil } })
        ) {
            Button("OK", role: .cancel) { photoOpenError = nil }
        } message: {
            Text(photoOpenError ?? "")
        }
        .modifier(PhotoChangeModifier(
            presentingPhotoPicker: $presentingPhotoPicker,
            photoPickerItem: $photoPickerItem,
            photoSaveError: $photoSaveError,
            isFilePanelOpen: $isFilePanelOpen,
            onPick: { item in Task { await addPicked(item) } },
            onPickFileData: { data, loadError in Task { await addFile(data, loadError: loadError) } }
        ))
    }

    @ViewBuilder
    private var content: some View {
        if firstLoadFailed {
            ContentUnavailableView {
                Label("Couldn’t Load Photos", systemImage: "exclamationmark.triangle")
            } description: {
                Text("This contact’s photos couldn’t be loaded right now.")
            } actions: {
                Button("Try Again") { loadGeneration += 1 }
            }
        } else if hasLoaded && items.isEmpty {
            ContentUnavailableView {
                Label("No Photos", systemImage: "photo.on.rectangle")
            } description: {
                Text("Photos you add to this contact appear here.")
            } actions: {
                Button("Add Photo") { presentingPhotoPicker = true }.disabled(isFilePanelOpen)
            }
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120, maximum: 220), spacing: 12)], spacing: 12) {
                    ForEach(items) { item in
                        ContactPhotoCell(
                            repository: repository,
                            contactID: contactID,
                            item: item,
                            generation: loadGeneration,
                            onView: { Task { await view(item) } },
                            onUseAsCurrent: {
                                Task { await change(operation: "swap") {
                                    try await repository.setCurrentContactPhoto(for: contactID, photoID: item.id)
                                } }
                            },
                            onDelete: { photoToDelete = item }
                        )
                        .disabled(isChanging)
                    }
                }
                .padding()
            }
        }
    }

    private func reload() async {
        do {
            let listed = try await repository.contactPhotos(for: contactID)
            guard !Task.isCancelled else { return }
            items = listed
            hasLoaded = true
            firstLoadFailed = false
        } catch {
            Self.log.error("photo list load failed", error.logContext(["contactID": contactID.logValue]))
            // After a timeout no reload may come, so a list that never appeared needs
            // its own way to try again. Once it has appeared, this reload just logs.
            if !hasLoaded { firstLoadFailed = true }
        }
    }

    private func view(_ item: ContactPhotoItem) async {
        do {
            guard let photo = try await repository.contactPhotoData(for: contactID, photoID: item.id) else {
                throw ContactPhotoEditError.photoPending
            }
            let image = await Task.detached(priority: .userInitiated) { photo.displayImage() }.value
            guard let image else { throw PickedPhoto.LoadError.notDecodable }
            viewerPhoto = FullscreenPhoto(image: image)
        } catch {
            Self.log.error("photo view load failed", error.logContext([
                "contactID": contactID.logValue, "photoID": item.id,
            ]))
            photoOpenError = error.localizedDescription
        }
    }

    /// A failed write can still have changed something, if Contacts couldn't be
    /// restored, so the refresh runs either way.
    private func change(operation: String, _ write: () async throws -> Void) async {
        isChanging = true
        defer { isChanging = false }
        onWillChange()
        do {
            try await write()
        } catch {
            Self.log.error("photo change failed", error.logContext([
                "contactID": contactID.logValue, "op": operation,
            ]))
            photoSaveError = error.localizedDescription
        }
        await onDidChange()
        loadGeneration += 1
    }

    private func addPicked(_ item: PhotosPickerItem) async {
        defer { photoPickerItem = nil }
        do {
            addRequest = AddPhotoRequest(photo: try await PickedPhoto.load(item))
        } catch {
            photoSaveError = error.localizedDescription
        }
    }

    private func addFile(_ data: Data?, loadError: Error?) async {
        do {
            addRequest = AddPhotoRequest(photo: try await PickedPhoto.decode(data, loadError: loadError))
        } catch {
            photoSaveError = error.localizedDescription
        }
    }
}

/// One photo in the grid, with its own thumbnail and menu. A cell loads its own
/// thumbnail so only the visible ones are read.
private struct ContactPhotoCell: View {
    private static let log = GuessWhoLog.logger("contact.photo")

    let repository: ContactsRepository
    let contactID: ContactID
    let item: ContactPhotoItem
    /// Bumped on every reload, so a photo that isn't here yet gets another try.
    let generation: Int
    let onView: () -> Void
    let onUseAsCurrent: () -> Void
    let onDelete: () -> Void

    /// The largest side of a tile's image. A tile can be about 540 pixels wide on a
    /// 3x iPhone.
    private nonisolated static let thumbnailMaxDimension: CGFloat = 600

    private enum Thumbnail {
        case loading
        case image(UIImage, crop: ContactPhotoCrop?)
        /// No bytes yet. The file may be downloading, or may be gone for good.
        case notHere
        case unavailable
        case undecodable
        case readFailed
    }

    private struct LoadKey: Equatable {
        let crop: ContactPhotoCrop?
        let generation: Int
    }

    @State private var loaded = Thumbnail.loading

    /// Unavailable from the list alone, before this cell's own read comes back.
    private var thumbnail: Thumbnail {
        if case .loading = loaded, !item.isAvailable { return .unavailable }
        return loaded
    }

    var body: some View {
        Group {
            switch thumbnail {
            case .image:
                Menu {
                    Button("View Photo", action: onView)
                    if !item.isCurrent {
                        Button("Use as Current Photo", action: onUseAsCurrent)
                    }
                    Button("Delete Photo", role: .destructive, action: onDelete)
                } label: {
                    tile
                }
                .accessibilityLabel(accessibilityLabel)
            case .notHere, .undecodable:
                Menu {
                    Button("Delete Photo", role: .destructive, action: onDelete)
                } label: {
                    tile
                }
                .accessibilityLabel(accessibilityLabel)
            case .loading, .unavailable, .readFailed:
                // A failed read can't rule out an older file another device may still
                // read, so there's nothing to offer. The next reload tries again.
                tile
            }
        }
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .task(id: LoadKey(crop: item.crop, generation: generation)) { await load() }
    }

    private var tile: some View {
        Color.secondary.opacity(0.15)
            .aspectRatio(1, contentMode: .fit)
            // An uncropped photo overflows its tile. Clipping only clips drawing, so
            // without this its overflow would catch taps meant for the next tile.
            .overlay { tileContent.allowsHitTesting(false) }
            .overlay(alignment: .bottom) {
                if item.isCurrent {
                    Text("Current")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.thinMaterial, in: Capsule())
                        .padding(6)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .contentShape(RoundedRectangle(cornerRadius: 12))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    private var tileContent: some View {
        switch thumbnail {
        case .loading:
            ProgressView()
        case .image(let image, _):
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        case .notHere:
            placeholder(systemImage: "photo", text: "Not available right now")
        case .unavailable:
            placeholder(systemImage: "photo", text: "Not available on this device")
        case .undecodable:
            placeholder(systemImage: "photo", text: "Can’t show this photo")
        case .readFailed:
            placeholder(systemImage: "exclamationmark.triangle", text: "Couldn’t load this photo")
        }
    }

    private func placeholder(systemImage: String, text: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.title2)
            Text(text)
                .font(.caption)
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(.secondary)
        .padding(8)
    }

    private var accessibilityLabel: String {
        var parts = [item.addedAt.map { "Photo added \($0.formatted(date: .abbreviated, time: .omitted))" } ?? "Photo"]
        switch thumbnail {
        case .loading, .image: break
        case .notHere: parts.append("not available right now")
        case .unavailable: parts.append("not available on this device")
        case .undecodable: parts.append("can’t be shown")
        case .readFailed: parts.append("couldn’t be loaded")
        }
        if item.isCurrent { parts.append("current") }
        return parts.joined(separator: ", ")
    }

    private func load() async {
        // A stored photo's bytes never change, so only a new crop means drawing it
        // again. The photo only Contacts holds, which has no date, can change.
        if case .image(_, let crop) = loaded, crop == item.crop, item.addedAt != nil { return }
        do {
            guard let photo = try await repository.contactPhotoData(for: contactID, photoID: item.id) else {
                loaded = .notHere
                return
            }
            let image = await Task.detached(priority: .userInitiated) {
                photo.displayImage(maxDimension: Self.thumbnailMaxDimension)
            }.value
            guard !Task.isCancelled else { return }
            loaded = image.map { .image($0, crop: photo.crop) } ?? .undecodable
        } catch ContactPhotoEditError.storedPhotoUnreadable {
            loaded = .unavailable
        } catch {
            // The next reload tries again.
            Self.log.error("photo thumbnail load failed", error.logContext([
                "contactID": contactID.logValue, "photoID": item.id,
            ]))
            loaded = .readFailed
        }
    }
}
