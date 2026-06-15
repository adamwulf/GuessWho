import Foundation

public enum SidecarStoreError: Error, Equatable {
    // The sidecar exists in remote storage but its bytes have not been
    // downloaded to this device yet. The store has requested the download;
    // the caller should retry `read()` later, or observe progress via
    // `downloadStatus(_:)` / `requestDownload(_:)`.
    case notYetDownloaded(SidecarKey)

    // A sidecar read/write/delete did not finish within the store's
    // per-attempt budget and the busy handler (see `SidecarBusyHandler`)
    // returned `.fail`. The default handler retries 3 times with
    // exponential backoff before failing; install a custom handler if you
    // want different semantics.
    case timedOut(SidecarKey)
}
