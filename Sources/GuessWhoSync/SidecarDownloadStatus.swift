import Foundation

// Reports the local-availability state of a sidecar for storage backends
// that may not have all bytes resident on this device. Backends that
// always have data locally return `.downloaded` for any known key and
// `.notFound` otherwise.
public enum SidecarDownloadStatus: Equatable {
    // Bytes are present locally; `read()` will succeed (subject to ordinary
    // I/O errors).
    case downloaded

    // A fetch is in progress.
    case downloading

    // The backend knows the sidecar exists in remote storage but no fetch
    // has been initiated yet. Callers should call `requestDownload(_:)`
    // and re-poll status.
    case notStarted

    // No sidecar exists at this key, either locally or in remote storage
    // (as far as the backend can tell). For purely local stores this
    // matches `read(_:)` returning `nil`.
    case notFound
}
