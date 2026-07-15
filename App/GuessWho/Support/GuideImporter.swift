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
        // guide is usable immediately and rows fill in one at a time as MapKit
        // answers (the resolver reloads the repository after each place).
        Task {
            await GuidePlaceResolver.resolvePlaces(
                inGuide: guideID, service: service, repository: repository
            )
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
///
/// The pass is **serial and rate-limited**: MapKit throttles bursts of
/// place-ID lookups (`MKError.loadingThrottled`), which on a large guide
/// leaves most rows stuck. We space requests `requestInterval` apart, back
/// off and retry a place that throttles, reload the repository after each
/// success so rows fill in one at a time, and publish which place is
/// currently being looked up (`resolvingPlaceID`) so the list can show a
/// per-row spinner. A per-guide in-flight guard stops two callers (the import
/// path and the list's on-open retry) from running duplicate passes and
/// doubling the request rate.
@MainActor
enum GuidePlaceResolver {
    private static let log = GuessWhoLog.logger("app.guides.resolve")

    /// Minimum spacing between MapKit lookups. Sized to stay under MapKit's
    /// place-ID rate limit; `.loadingThrottled` responses trigger the longer
    /// backoff below on top of this. Bump toward `.seconds(3)` if throttling
    /// persists.
    static let requestInterval: Duration = .seconds(1)

    /// How many times a single throttled place is retried before we give up on
    /// it for this pass (it stays pending and retries on the next guide open).
    private static let maxThrottleRetries = 3

    /// Guards against overlapping passes for the same guide — the import task
    /// and the list controller's on-open retry both call `resolvePlaces`.
    private static var inFlightGuides: Set<UUID> = []

    /// The place currently being looked up, or nil when no pass is active.
    /// Read by the places list to render its per-row status (a spinner on this
    /// row, "waiting" on the other unresolved rows). Changes post
    /// `.guideResolutionActivePlaceDidChange`.
    private(set) static var resolvingPlaceID: UUID?

    /// True while a resolution pass is running for `guideID`. Lets the list
    /// distinguish "queued, a pass is working through them" from "no pass
    /// running" for its unresolved rows.
    static func isResolving(guide guideID: UUID) -> Bool {
        inFlightGuides.contains(guideID)
    }

    private static func setResolving(_ id: UUID?) {
        guard resolvingPlaceID != id else { return }
        resolvingPlaceID = id
        NotificationCenter.default.post(name: .guideResolutionActivePlaceDidChange, object: nil)
    }

    /// Resolve every place in `guideID` that still needs it, reloading
    /// `repository` after each one so the list fills in live. Serial and
    /// rate-limited — see the type doc.
    static func resolvePlaces(
        inGuide guideID: UUID,
        service: SyncService,
        repository: GuidesRepository
    ) async {
        // Claim the guide atomically: the check and insert must not straddle an
        // `await`, or two callers (import + on-open retry) could both pass the
        // guard before either inserts and run duplicate passes. Everything up to
        // here is synchronous on the main actor, so this is race-free.
        guard !inFlightGuides.contains(guideID) else { return }
        inFlightGuides.insert(guideID)
        defer {
            inFlightGuides.remove(guideID)
            setResolving(nil)
        }

        let places = await service.places(inGuide: guideID)
        let pending = places.filter(\.needsResolution)
        guard !pending.isEmpty else { return }

        guard #available(iOS 18.0, macCatalyst 18.0, *) else {
            log.notice("resolve: place-ID lookup unavailable on this OS", [
                "pending": pending.count
            ])
            return
        }

        // Announce the pass so already-unresolved rows flip to "waiting".
        NotificationCenter.default.post(name: .guideResolutionActivePlaceDidChange, object: nil)

        var resolved = 0
        for (index, place) in pending.enumerated() {
            guard let rawID = place.mapsPlaceID,
                  let identifier = MKMapItem.Identifier(rawValue: rawID)
            else { continue }

            // Space requests apart (skip the wait before the very first one).
            if index > 0 {
                try? await Task.sleep(for: requestInterval)
            }
            setResolving(place.id)

            if await resolveOne(
                place: place, identifier: identifier, service: service, repository: repository
            ) {
                resolved += 1
            }
        }
        log.notice("resolve: pass complete", [
            "resolved": resolved,
            "pending": pending.count - resolved
        ])
    }

    /// Look up one place, retrying with backoff while MapKit throttles us.
    /// Returns true on success. On success writes the resolution and reloads
    /// the repository so the row repaints immediately.
    @available(iOS 18.0, macCatalyst 18.0, *)
    private static func resolveOne(
        place: MapsPlace,
        identifier: MKMapItem.Identifier,
        service: SyncService,
        repository: GuidesRepository
    ) async -> Bool {
        var attempt = 0
        while true {
            do {
                let details = try await resolvedDetails(for: identifier)
                try service.markPlaceResolved(
                    uuid: place.id.uuidString,
                    name: details.name ?? "",
                    address: details.address,
                    latitude: details.latitude,
                    longitude: details.longitude
                )
                await repository.reload()
                return true
            } catch {
                if isThrottled(error), attempt < maxThrottleRetries {
                    attempt += 1
                    // Escalating backoff: 4s, 8s, 16s. MapKit clears the
                    // throttle after a short cool-down, so a few waits usually
                    // let the same place through.
                    let backoff = Duration.seconds(4 << (attempt - 1))
                    log.notice("resolve: throttled, backing off", [
                        "placeID": place.mapsPlaceID ?? "-",
                        "attempt": String(attempt),
                        "backoffSeconds": String(4 << (attempt - 1))
                    ])
                    try? await Task.sleep(for: backoff)
                    continue
                }
                // Give up for this pass — the place stays pending and retries
                // the next time the guide opens. Transient network failures and
                // genuinely-gone places look the same here.
                log.notice("resolve: lookup failed", [
                    "placeID": place.mapsPlaceID ?? "-",
                    "error": error.localizedDescription
                ])
                return false
            }
        }
    }

    /// Whether `error` is MapKit telling us to slow down.
    private static func isThrottled(_ error: Error) -> Bool {
        (error as? MKError)?.code == .loadingThrottled
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
