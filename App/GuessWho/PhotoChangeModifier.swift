import SwiftUI
import PhotosUI
import GuessWhoLogging

/// A chosen or dropped image, decoded for the crop editor. Its original bytes are
/// kept as they are.
struct PickedPhoto {
    private static let log = GuessWhoLog.logger("contact.photo")

    let data: Data
    let image: UIImage

    enum LoadError: LocalizedError {
        case notLoaded
        case notDecodable

        var errorDescription: String? {
            switch self {
            case .notLoaded: return "That photo couldn’t be loaded."
            case .notDecodable: return "That photo couldn’t be processed."
            }
        }
    }

    static func load(_ item: PhotosPickerItem) async throws -> PickedPhoto {
        let data: Data?
        do {
            data = try await item.loadTransferable(type: Data.self)
        } catch {
            log.error("photo picker load failed", error.logCodes())
            throw error
        }
        return try await decode(data, loadError: nil)
    }

    /// Photos, file selection, and drops all come through here.
    static func decode(_ rawData: Data?, loadError: Error?) async throws -> PickedPhoto {
        guard let rawData else {
            log.error("photo load returned no data", loadError?.logCodes() ?? [:])
            throw loadError ?? LoadError.notLoaded
        }
        let image = await Task.detached(priority: .userInitiated) { UIImage(data: rawData) }.value
        guard let image else {
            log.error("photo decode failed", ["bytes": rawData.count])
            throw LoadError.notDecodable
        }
        return PickedPhoto(data: rawData, image: image)
    }
}

/// Bundles the photo-change surfaces — the platform picker (`PhotosPicker` on
/// iOS/iPadOS, a file Open panel on Catalyst) and the failure alert — into one
/// modifier, shared by the contact card and All Photos. It also keeps
/// `ContactDetailView.body`'s modifier chain within the type-checker's budget.
///
/// Catalyst gets a real file-system Open panel, not the Photos picker: Catalyst
/// users expect to browse the filesystem (Finder, AirDropped files, external
/// drives), and `PhotosPicker` only surfaces the Photos library grid there.
struct PhotoChangeModifier: ViewModifier {
    @Binding var presentingPhotoPicker: Bool
    @Binding var photoPickerItem: PhotosPickerItem?
    @Binding var photoSaveError: String?
    /// True while the Mac file panel is up. It's modeless, so the caller must keep
    /// anything from closing its view or starting another panel until this clears.
    @Binding var isFilePanelOpen: Bool
    let onPick: (PhotosPickerItem) -> Void
    let onPickFileData: (Data?, Error?) -> Void

    func body(content: Content) -> some View {
        content
            #if targetEnvironment(macCatalyst)
            // Catalyst drives a native, in-process `NSOpenPanel` through the
            // AppKitBridge bundle rather than a `UIDocumentPickerViewController`:
            // the latter's presenter detaches from the window mid-present on
            // Catalyst, so the powerbox never shows and the whole window
            // deadlocks (no dialog, frozen to mouse input). The bundle runs the
            // panel modelessly on the main thread and calls back with the URLs.
            //
            // Hung off `onChange(of: presentingPhotoPicker)` rather than a
            // `.sheet` so existing call sites that just set
            // `presentingPhotoPicker = true` keep working. Reset the flag
            // immediately (the panel is its own window, not a SwiftUI
            // presentation) so the next tap re-triggers.
            .onChange(of: presentingPhotoPicker) { _, isPresenting in
                guard isPresenting else { return }
                presentingPhotoPicker = false
                guard !isFilePanelOpen else { return }
                presentOpenPanelForPhoto()
            }
            #else
            .photosPicker(isPresented: $presentingPhotoPicker, selection: $photoPickerItem,
                          matching: .images, preferredItemEncoding: .current)
            .onChange(of: photoPickerItem) { _, newItem in
                guard let newItem else { return }
                onPick(newItem)
            }
            #endif
            .alert(
                "Couldn't update photo",
                isPresented: Binding(
                    get: { photoSaveError != nil },
                    set: { if !$0 { photoSaveError = nil } }
                )
            ) {
                Button("OK", role: .cancel) { photoSaveError = nil }
            } message: {
                Text(photoSaveError ?? "")
            }
    }

    #if targetEnvironment(macCatalyst)
    /// Drives the native macOS file Open panel (via the in-process AppKitBridge
    /// bundle) and feeds the picked image's bytes into the shared crop editor
    /// tail as raw `Data`, matching the `NSItemProvider` shape the drag-and-drop
    /// path uses. The panel's completion fires on the main thread; we read the
    /// file off it so a large image can't stall the UI, then hop back.
    private func presentOpenPanelForPhoto() {
        guard let bridge = AppKitBridgeLoader.shared else {
            // Bundle failed to load — surface a plain-language error rather than
            // silently no-op'ing the tap. (AppKitBridgeLoader logs the debug
            // breadcrumbs.)
            photoSaveError = "The photo picker couldn't be opened."
            return
        }
        isFilePanelOpen = true
        bridge.presentOpenPanel(
            allowedExtensions: ["png", "jpg", "jpeg", "heic", "heif", "gif", "tiff", "bmp", "webp"],
            allowsMultiple: false
        ) { urls in
            // Main thread; an empty array means the user cancelled.
            isFilePanelOpen = false
            guard let url = urls.first else { return }
            // The in-process panel selection is already blessed against the
            // sandbox, so a same-launch read needs no security-scoped bracket;
            // we keep the defensive start/stop anyway (harmless) and read off
            // the main thread so a large file doesn't stall the UI.
            let didStartAccessing = url.startAccessingSecurityScopedResource()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { if didStartAccessing { url.stopAccessingSecurityScopedResource() } }
                do {
                    let data = try Data(contentsOf: url)
                    DispatchQueue.main.async { onPickFileData(data, nil) }
                } catch {
                    DispatchQueue.main.async { onPickFileData(nil, error) }
                }
            }
        }
    }
    #endif
}
