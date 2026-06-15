import Foundation

// Reports the local-availability state of a sidecar for storage backends
// that may not have all bytes resident on this device (e.g. iCloud Drive).
// Storage that always has data locally returns `.downloaded` for any key
// it knows about and `.notFound` otherwise.
public enum SidecarDownloadStatus: Equatable {
    // Bytes are present locally; `read()` will succeed (subject to ordinary
    // I/O errors).
    case downloaded

    // A fetch is in progress. `fractionComplete` is between 0 and 1 when
    // known, or `nil` when the backend can't report progress.
    case downloading(fractionComplete: Double?)

    // The backend knows the sidecar exists in remote storage but no fetch
    // has been initiated yet. Callers should call `requestDownload(_:)`
    // and re-poll status.
    case notStarted

    // No sidecar exists at this key, either locally or in remote storage
    // (as far as the backend can tell).
    case notFound
}
