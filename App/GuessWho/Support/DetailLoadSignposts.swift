import Foundation
import os.signpost

/// Points-of-interest signposts around the detail-page load pipeline
/// (`ContactDetailView`, `EventDetailView`). Instruments' os_signpost track
/// shows each region as a named interval, so a Time Profiler trace of a
/// navigation answers "where did the open spend its time" directly —
/// resolve, sidecar stores, link walks, EventKit attendee scan, groups,
/// guides, photo. The regions are the measurement infrastructure for
/// detail-load profiling (the signpost analog of the `sync.contact-fetch` /
/// `sync.eventkit-fetch` log breadcrumbs) and are kept in Release builds:
/// `.pointsOfInterest` signposts are near-free when no tool is recording.
enum DetailLoadSignpost {
    /// One log handle for every detail-load region. The subsystem matches the
    /// app's Release bundle id so traces filter on one constant string in
    /// both build configurations.
    static let log = OSLog(subsystem: "com.milestonemade.guesswho", category: .pointsOfInterest)

    /// Begin a named interval. Returns the id `end(_:_:)` needs — regions can
    /// nest and interleave, so each interval carries its own signpost id.
    static func begin(_ name: StaticString, _ message: String = "") -> OSSignpostID {
        let id = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: name, signpostID: id, "%{public}s", message)
        return id
    }

    static func end(_ name: StaticString, _ id: OSSignpostID, _ message: String = "") {
        os_signpost(.end, log: log, name: name, signpostID: id, "%{public}s", message)
    }

    /// A single point-in-time marker (no duration) — used by the DEBUG
    /// navigation benchmark to mark each driven navigation in the trace.
    static func event(_ name: StaticString, _ message: String = "") {
        os_signpost(.event, log: log, name: name, signpostID: .exclusive, "%{public}s", message)
    }

    /// Wrap one async load step in a begin/end pair. `@MainActor` (helper and
    /// closure both): every detail loader is main-actor-isolated, so this
    /// avoids sending a non-Sendable closure across actors, and begin/end land
    /// on the main thread where per-thread signpost aggregation pairs them.
    @MainActor
    static func measure<T>(
        _ name: StaticString,
        _ message: String = "",
        _ body: @MainActor () async -> T
    ) async -> T {
        let id = begin(name, message)
        defer { end(name, id) }
        return await body()
    }

    /// Sync-step variant of `measure` for the synchronous main-actor reads
    /// (notes/fields envelope reads, cached-event lookups).
    @MainActor
    static func measureSync<T>(
        _ name: StaticString,
        _ message: String = "",
        _ body: @MainActor () -> T
    ) -> T {
        let id = begin(name, message)
        defer { end(name, id) }
        return body()
    }
}
