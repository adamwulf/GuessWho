import SwiftUI

/// Inline status row that surfaces whether sidecar storage is on iCloud,
/// in the local fallback, or unavailable. Rendered as the first row of
/// each list view so it scrolls with the content instead of floating
/// over the tab bar.
struct SidecarLocationBanner: View {
    let location: SyncService.SidecarLocation

    var body: some View {
        switch location {
        case .iCloud:
            EmptyView()
        case .localFallback(_, let reason):
            Label {
                Text(reason).font(.footnote)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            .padding(8)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
        case .unavailable(let reason):
            Label {
                Text("Storage is unavailable. \(reason)")
                    .font(.footnote)
            } icon: {
                Image(systemName: "xmark.octagon.fill")
                    .foregroundStyle(.red)
            }
            .padding(8)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
        }
    }
}

extension SyncService.SidecarLocation {
    /// True when this location warrants a visible banner. The happy path
    /// (.iCloud) reads as "everything is normal" and shows nothing.
    var needsBanner: Bool {
        switch self {
        case .iCloud: return false
        case .localFallback, .unavailable: return true
        }
    }
}
