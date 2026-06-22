import Foundation

/// Result of `GuessWhoSync.migrateEventsToSidecarFirst()` (E5.1).
///
/// `migratedEvents` carries one entry per legacy `events/<eventIdentifier>`
/// sidecar that was translated to a fresh UUID-keyed envelope this pass. The
/// `oldExternalID` tuple label is kept stable for the spec'd shape — its
/// VALUE is the pre-pivot legacy `eventIdentifier` string in its original
/// case (the string the file was named with on disk), NOT a
/// `calendarItemExternalIdentifier`.
///
/// `rewrittenLinkIDs` is the flat list of `Link` UUIDs whose endpoint A
/// and/or B was rewritten from `(.event, legacyEventIdentifier)` to
/// `(.event, newEventUUID)` during step 2 of the migration.
///
/// `skipped` lists event sidecar keys that the migration deliberately
/// skipped (already-UUID-keyed envelopes with a live `eventKitID` cell).
public struct EventMigrationReport: Sendable {
    public let migratedEvents: [(oldExternalID: String, newUUID: UUID)]
    public let rewrittenLinkIDs: [UUID]
    public let skipped: [String]

    public init(
        migratedEvents: [(oldExternalID: String, newUUID: UUID)],
        rewrittenLinkIDs: [UUID],
        skipped: [String]
    ) {
        self.migratedEvents = migratedEvents
        self.rewrittenLinkIDs = rewrittenLinkIDs
        self.skipped = skipped
    }
}
