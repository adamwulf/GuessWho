import Foundation

public enum SidecarStoreError: Error, Equatable {
    // The sidecar exists in the ubiquity container but its bytes have not
    // been downloaded to this device yet. A download has been requested;
    // the caller should re-attempt `read()` later — or use
    // `requestDownload(_:)` + `downloadStatus(_:)` to observe progress
    // domain-style.
    case notYetDownloaded(SidecarKey)

    // A coordinated read/write/delete did not return within the per-attempt
    // budget and the busy handler (see `SidecarBusyHandler`) returned
    // `.fail`. The default handler ships with a 3-attempt budget and
    // exponential backoff; host apps can install a custom handler if they
    // want different semantics. No cloudd vocabulary is exposed.
    case timedOut(SidecarKey)
}
