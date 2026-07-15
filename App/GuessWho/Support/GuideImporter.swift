import Foundation
import MapKit
import GuessWhoSync
import GuessWhoLogging

/// The one import path for an Apple Maps guide share link, used by every
/// entry point (the Guides list's "+" paste flow, and the share-extension /
/// deep-link wake): fetch + decode the link, store the guide, reload the
/// repository, then kick the MapKit resolution pass in the background.
@MainActor
enum GuideImporter {
    /// Guide-import breadcrumbs route through swift-log to
    /// `<AppGroup>/Logs/app.log`. Developer-facing label; see GuessWhoLogging
    /// notes.
    private static let log = GuessWhoLog.logger("app.guides.import")

    /// Import the guide behind `url`. Throws when the link can't be fetched,
    /// isn't a guide link, or storage is unavailable. Returns the new guide's
    /// UUID after the repository has reloaded (so callers can navigate to it);
    /// place resolution continues in the background and reloads again as
    /// details land.
    @discardableResult
    static func importGuide(
        from url: URL,
        service: SyncService,
        repository: GuidesRepository
    ) async throws -> UUID {
        log.notice("import: fetching guide link", ["host": url.host ?? "-"])
        let snapshot = try await MapsGuideURL.fetchSnapshot(from: url)
        log.notice("import: decoded guide", [
            "name": snapshot.name,
            "entries": snapshot.entries.count
        ])
        let guideID = try service.importGuide(from: snapshot, sourceURL: url.absoluteString)
        await repository.reload()

        // Resolve place IDs into names/addresses off the import path — the
        // guide is usable immediately and rows fill in as MapKit answers.
        Task {
            await GuidePlaceResolver.resolvePlaces(inGuide: guideID, service: service)
            await repository.reload()
        }
        return guideID
    }
}

/// Resolves imported place IDs into display fields via MapKit's place-ID
/// lookup (`MKMapItemRequest(mapItemIdentifier:)`, iOS 18+). Address entries
/// import fully-formed and never pass through here; place-ID entries start
/// as bare identifiers and get name/address/coordinate filled in.
///
/// On OS versions without the place-ID API the pass is a silent no-op — the
/// rows keep showing "Loading place details…" and resolve after an OS
/// update. Failed lookups stay unresolved and retry on the next pass.
@MainActor
enum GuidePlaceResolver {
    private static let log = GuessWhoLog.logger("app.guides.resolve")

    /// Resolve every place in `guideID` that still needs it. Serial on
    /// purpose: guides carry tens of places at most, and one-at-a-time keeps
    /// us politely under any MapKit throttling.
    static func resolvePlaces(inGuide guideID: UUID, service: SyncService) async {
        let places = await service.places(inGuide: guideID)
        let pending = places.filter(\.needsResolution)
        guard !pending.isEmpty else { return }

        guard #available(iOS 18.0, macCatalyst 18.0, *) else {
            log.notice("resolve: place-ID lookup unavailable on this OS", [
                "pending": pending.count
            ])
            return
        }

        var resolved = 0
        for place in pending {
            guard let rawID = place.mapsPlaceID,
                  let identifier = MKMapItem.Identifier(rawValue: rawID)
            else { continue }
            do {
                let details = try await resolvedDetails(for: identifier)
                try service.markPlaceResolved(
                    uuid: place.id.uuidString,
                    name: details.name ?? "",
                    address: details.address,
                    latitude: details.latitude,
                    longitude: details.longitude
                )
                resolved += 1
            } catch {
                // Leave unresolved — the next pass retries. Transient network
                // failures and genuinely-gone places look the same here.
                log.notice("resolve: lookup failed", [
                    "placeID": rawID,
                    "error": error.localizedDescription
                ])
            }
        }
        log.notice("resolve: pass complete", [
            "resolved": resolved,
            "pending": pending.count - resolved
        ])
    }

    /// The Sendable subset of a resolved `MKMapItem` this pass stores.
    /// Extracted inside the request callback so the non-Sendable `MKMapItem`
    /// never crosses the continuation.
    private struct ResolvedDetails: Sendable {
        let name: String?
        let address: String?
        let latitude: Double
        let longitude: Double
    }

    @available(iOS 18.0, macCatalyst 18.0, *)
    private static func resolvedDetails(
        for identifier: MKMapItem.Identifier
    ) async throws -> ResolvedDetails {
        let request = MKMapItemRequest(mapItemIdentifier: identifier)
        return try await withCheckedThrowingContinuation { continuation in
            request.getMapItem { item, error in
                if let item {
                    continuation.resume(returning: ResolvedDetails(
                        name: item.name,
                        address: item.placemark.title,
                        latitude: item.placemark.coordinate.latitude,
                        longitude: item.placemark.coordinate.longitude
                    ))
                } else {
                    continuation.resume(throwing: error ?? CocoaError(.fileNoSuchFile))
                }
            }
        }
    }
}
