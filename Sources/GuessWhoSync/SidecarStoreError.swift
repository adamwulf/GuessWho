import Foundation

public enum SidecarStoreError: Error, Equatable {
    // The sidecar exists in the ubiquity container but its bytes have not
    // been downloaded to this device yet. A download has been requested;
    // the caller should re-attempt `read()` later.
    case notYetDownloaded(SidecarKey)
}
