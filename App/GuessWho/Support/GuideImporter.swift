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
    /// UUID after the repository has reloaded (so callers can navigate to it).
    /// When the original, pre-redirect URL exactly matches a stored source URL,
    /// storage refreshes that guide in place and returns its existing UUID
    /// rather than creating a duplicate. Place resolution continues in the
    /// background and reloads again as details land.
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

    /// Re-fetch an imported guide's saved source URL and reconcile the new
    /// snapshot into that same guide UUID. Returns the decoded snapshot so the
    /// visible controller can update its title immediately; place resolution
    /// continues in the background just like a first import.
    static func refreshGuide(
        _ guide: MapsGuide,
        service: SyncService,
        repository: GuidesRepository
    ) async throws -> MapsGuideURL.Snapshot {
        guard let rawURL = guide.sourceURL,
              let url = URL(string: rawURL)
        else { throw GuideRefreshError.missingSourceURL }

        log.notice("refresh: fetching guide link", [
            "guideID": guide.id.uuidString,
            "host": url.host ?? "-"
        ])
        let snapshot = try await MapsGuideURL.fetchSnapshot(from: url)
        let updated = try service.refreshGuide(
            uuid: guide.id.uuidString,
            from: snapshot,
            sourceURL: rawURL
        )
        guard updated else { throw GuideRefreshError.guideNoLongerExists }

        log.notice("refresh: updated guide", [
            "guideID": guide.id.uuidString,
            "name": snapshot.name,
            "entries": snapshot.entries.count
        ])
        await repository.reload()

        Task {
            await GuidePlaceResolver.resolvePlaces(
                inGuide: guide.id, service: service, repository: repository
            )
        }
        return snapshot
    }
}

enum GuideRefreshError: LocalizedError {
    case missingSourceURL
    case guideNoLongerExists

    var errorDescription: String? {
        switch self {
        case .missingSourceURL:
            return "This guide does not have its original Apple Maps link."
        case .guideNoLongerExists:
            return "This guide was removed before it could be refreshed."
        }
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

    /// Minimum spacing between MapKit lookups in the steady state. Kept short
    /// so a large guide fills in quickly; when MapKit pushes back with
    /// `.loadingThrottled` the per-place backoff below takes over (starting at
    /// 1s) to slow things down. Bump this up if throttling persists from the
    /// very first requests.
    static let requestInterval: Duration = .milliseconds(200)

    /// How many times a single throttled place is retried before we give up on
    /// it for this pass (it stays pending and retries on the next guide open).
    private static let maxThrottleRetries = 3

    /// Guards against overlapping passes for the same guide — the import task
    /// and the list controller's on-open retry both call `resolvePlaces`.
    private static var inFlightGuides: Set<UUID> = []

    /// A refresh can add entries while an older resolution pass is still
    /// walking its captured snapshot. Coalesce that overlap into one follow-up
    /// pass so newly added place IDs do not wait until the guide is reopened.
    private static var requestedReruns: Set<UUID> = []

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
        guard !inFlightGuides.contains(guideID) else {
            requestedReruns.insert(guideID)
            return
        }
        inFlightGuides.insert(guideID)
        defer {
            inFlightGuides.remove(guideID)
            setResolving(nil)
            if requestedReruns.remove(guideID) != nil {
                Task {
                    await resolvePlaces(
                        inGuide: guideID, service: service, repository: repository
                    )
                }
            }
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
                    // Escalating backoff: 1s, 2s, 4s. The steady-state spacing
                    // is only 0.2s, so the first throttle bumps us up to 1s and
                    // grows from there. MapKit clears the throttle after a short
                    // cool-down, so a few waits usually let the same place through.
                    let backoffSeconds = 1 << (attempt - 1)
                    let backoff = Duration.seconds(backoffSeconds)
                    log.notice("resolve: throttled, backing off", [
                        "placeUUID": place.id.uuidString,
                        "placeID": place.mapsPlaceID ?? "-",
                        "attempt": String(attempt),
                        "backoffSeconds": String(backoffSeconds)
                    ])
                    try? await Task.sleep(for: backoff)
                    continue
                }
                // Give up for this pass — the place stays pending and retries
                // the next time the guide opens. Log at `.error` with the full
                // error breakdown + place metadata: for a place that never
                // resolves even on repeat passes, `error.localizedDescription`
                // alone (usually the generic "operation couldn't be completed")
                // isn't enough to tell throttling from an unknown identifier
                // from MapKit returning nothing at all.
                var metadata = placeMetadata(place, identifier: identifier)
                metadata["attempts"] = String(attempt + 1)
                metadata.merge(errorMetadata(error)) { current, _ in current }
                log.error("resolve: lookup failed", metadata)
                return false
            }
        }
    }

    /// Whether `error` is MapKit telling us to slow down.
    private static func isThrottled(_ error: Error) -> Bool {
        (error as? MKError)?.code == .loadingThrottled
    }

    /// Failure modes this pass raises itself (as opposed to errors MapKit
    /// hands back). Kept distinct so the failure log names the real cause.
    private enum ResolutionError: LocalizedError {
        /// `MKMapItemRequest.getMapItem` called back with neither an item nor
        /// an error — no place, no reason. A likely fingerprint for a place-ID
        /// that has gone stale/unresolvable in MapKit's catalog.
        case mapKitReturnedNothing

        var errorDescription: String? {
            switch self {
            case .mapKitReturnedNothing:
                return "MapKit returned neither a map item nor an error"
            }
        }
    }

    /// Identifying fields for `place`, so a failure line can be tied back to
    /// the exact row (and its Apple Maps identifier) in the log.
    private static func placeMetadata(
        _ place: MapsPlace,
        identifier: MKMapItem.Identifier
    ) -> [String: CustomStringConvertible] {
        [
            "placeUUID": place.id.uuidString,
            "guideID": place.guideID.uuidString,
            "placeID": place.mapsPlaceID ?? "-",
            "identifier": identifier.rawValue,
            "name": place.name.isEmpty ? "-" : place.name,
            "sortOrder": String(place.sortOrder)
        ]
    }

    /// Decompose `error` into the fields that actually explain a resolution
    /// failure: the bridged `NSError` domain/code (present even when the
    /// localized description is the generic "operation couldn't be completed"),
    /// the specific `MKError` case when MapKit is the source, and any
    /// underlying error it wraps.
    private static func errorMetadata(_ error: Error) -> [String: CustomStringConvertible] {
        let nsError = error as NSError
        var metadata: [String: CustomStringConvertible] = [
            "error": error.localizedDescription,
            "errorDomain": nsError.domain,
            "errorCode": String(nsError.code)
        ]
        if let mkError = error as? MKError {
            metadata["mkErrorCode"] = mkErrorCodeName(mkError.code)
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            metadata["underlyingDomain"] = underlying.domain
            metadata["underlyingCode"] = String(underlying.code)
        }
        return metadata
    }

    /// A stable, greppable name for an `MKError.Code` (the raw enum prints as
    /// its integer, which is opaque in a log line).
    private static func mkErrorCodeName(_ code: MKError.Code) -> String {
        switch code {
        case .unknown: return "unknown"
        case .serverFailure: return "serverFailure"
        case .loadingThrottled: return "loadingThrottled"
        case .placemarkNotFound: return "placemarkNotFound"
        case .directionsNotFound: return "directionsNotFound"
        case .decodingFailed: return "decodingFailed"
        @unknown default: return "unmapped(\(code.rawValue))"
        }
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
                    // Distinguish "MapKit reported a failure" from "MapKit
                    // called back with neither an item nor an error" — the
                    // latter is a plausible signature for a place-ID that no
                    // longer resolves, and folding it into a generic Cocoa
                    // error would hide that in the logs.
                    continuation.resume(throwing: error ?? ResolutionError.mapKitReturnedNothing)
                }
            }
        }
    }
}
