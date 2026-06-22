import Foundation
import Testing
@testable import GuessWhoSync
import GuessWhoSyncTesting

@Suite("EventMigration")
struct EventMigrationTests {

    private func makeOrchestrator(
        deviceID: String = "device-A"
    ) -> (GuessWhoSync, InMemorySidecarStore, InMemoryEventStore) {
        let contacts = InMemoryContactStore()
        let events = InMemoryEventStore()
        let sidecars = InMemorySidecarStore()
        let sync = GuessWhoSync(
            contacts: contacts,
            events: events,
            sidecars: sidecars,
            deviceID: deviceID
        )
        return (sync, sidecars, events)
    }

    /// Write a legacy `events/<legacyEventIdentifier>` sidecar envelope
    /// directly into the store, bypassing the orchestrator API. Optionally
    /// includes a single `note`-type field-instance cell so the migration's
    /// pre-existing-cell preservation can be verified.
    private func seedLegacyEnvelope(
        in sidecars: InMemorySidecarStore,
        legacyID: String,
        noteText: String? = nil
    ) throws -> (key: SidecarKey, noteInstanceID: UUID?) {
        let key = SidecarKey(kind: .event, id: legacyID)
        var fields: [String: SidecarCell] = [:]
        var noteID: UUID? = nil
        if let noteText {
            let id = UUID()
            let now = Date()
            let inner = SidecarField.makeInnerValue(
                field: GuessWhoSync.contactNoteFieldName,
                type: .note,
                value: .string(noteText),
                createdAt: now
            )
            fields[id.uuidString] = SidecarCell(
                value: inner,
                modifiedAt: now,
                modifiedBy: "seed"
            )
            noteID = id
        }
        let envelope = SidecarEnvelope(
            schemaVersion: 1,
            entityID: key.id,
            fields: fields
        )
        try sidecars.write(envelope, at: key)
        return (key, noteID)
    }

    private func cellStringValue(_ cell: SidecarCell) -> String? {
        guard case .object(let inner) = cell.value,
              case .string(let value) = inner[SidecarField.innerValueKey] ?? .null
        else { return nil }
        return value
    }

    // MARK: - Identifier translation

    @Test
    func migratesLegacyEventIdentifierKeyedSidecarTranslatesToCalendarItemExternalIdentifier() throws {
        let (sync, sidecars, events) = makeOrchestrator()
        // Legacy `eventIdentifier` (the pre-pivot sidecar key) and the
        // post-pivot canonical id the mock will hand back.
        let legacyID = "legacy-event-id-001"
        let ekidNew = "ek-canonical-001"

        // Pre-seed a real EKEvent in the in-memory store keyed by ekidNew,
        // and tell the mock that legacyID translates to ekidNew (mirrors
        // EventKit's `event(withIdentifier:)` → `calendarItemExternalIdentifier`
        // lookup).
        let start = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let end = start.addingTimeInterval(3600)
        let seeded = Event(
            id: Event.stableID(forEventKitID: ekidNew),
            eventKitID: ekidNew,
            title: "Live EK Title",
            startDate: start,
            endDate: end,
            isAllDay: false,
            location: "Office",
            eventKitNotes: nil
        )
        // Inject the EKEvent + the translation map entry.
        let (event, _) = try _injectEventAndTranslation(
            into: events,
            event: seeded,
            legacy: legacyID
        )
        #expect(event.eventKitID == ekidNew)

        // Seed a legacy envelope with a single note instance.
        let seed = try seedLegacyEnvelope(
            in: sidecars,
            legacyID: legacyID,
            noteText: "from before the pivot"
        )

        let report = try sync.migrateEventsToSidecarFirst()
        #expect(report.migratedEvents.count == 1)
        let migrated = try #require(report.migratedEvents.first)
        // Legacy id remembered in the report; new UUID assigned.
        #expect(migrated.oldExternalID == legacyID)

        // Old legacy key gone.
        #expect(try sidecars.read(seed.key) == nil)

        // New UUID-keyed envelope exists with the canonical eventKitID and
        // the preserved note.
        let newKey = SidecarKey(kind: .event, id: migrated.newUUID.uuidString)
        let newEnvelope = try #require(try sidecars.read(newKey))
        let ekidCell = try #require(newEnvelope.fields[GuessWhoSync.eventKitIDCellKey])
        #expect(cellStringValue(ekidCell) == ekidNew)
        #expect(cellStringValue(ekidCell) != legacyID)

        // Note instance preserved verbatim.
        let noteID = try #require(seed.noteInstanceID)
        let preservedNote = try #require(newEnvelope.fields[noteID.uuidString])
        #expect(cellStringValue(preservedNote) == "from before the pivot")

        // Title cache seeded from EventKit.
        let titleCell = try #require(newEnvelope.fields[GuessWhoSync.eventTitleCacheKey])
        #expect(cellStringValue(titleCell) == "Live EK Title")
    }

    @Test
    func migratesLegacyEventIdentifierWithGoneEKEventToDeadPointer() throws {
        let (sync, sidecars, _) = makeOrchestrator()
        let legacyID = "legacy-event-id-002"
        let seed = try seedLegacyEnvelope(in: sidecars, legacyID: legacyID)

        let report = try sync.migrateEventsToSidecarFirst()
        let migrated = try #require(report.migratedEvents.first)
        #expect(migrated.oldExternalID == legacyID)

        let newKey = SidecarKey(kind: .event, id: migrated.newUUID.uuidString)
        let newEnvelope = try #require(try sidecars.read(newKey))
        let ekidCell = try #require(newEnvelope.fields[GuessWhoSync.eventKitIDCellKey])

        // Dead pointer: the cell holds the ORIGINAL legacy `eventIdentifier`
        // (not lost) so the dual-namespace resolver can still chase it later.
        #expect(cellStringValue(ekidCell) == legacyID)

        // Cache cells are NOT written for the dead-pointer case.
        #expect(newEnvelope.fields[GuessWhoSync.eventTitleCacheKey] == nil)
        #expect(newEnvelope.fields[GuessWhoSync.eventStartCacheKey] == nil)

        // `isLinked == true` (the cell exists and is not soft-deleted).
        let projected = try #require(try sync.event(at: newKey))
        #expect(projected.isLinked == true)
        #expect(projected.title.isEmpty)

        // Old legacy key removed.
        #expect(try sidecars.read(seed.key) == nil)
    }

    @Test
    func migrationIsIdempotent() throws {
        let (sync, sidecars, events) = makeOrchestrator()
        let legacyID = "legacy-event-id-idempotent"
        let ekid = "ek-idempotent"
        let event = Event(
            id: Event.stableID(forEventKitID: ekid),
            eventKitID: ekid,
            title: "Idem",
            startDate: Date(),
            endDate: Date().addingTimeInterval(60),
            isAllDay: false,
            location: nil,
            eventKitNotes: nil
        )
        _ = try _injectEventAndTranslation(into: events, event: event, legacy: legacyID)
        _ = try seedLegacyEnvelope(in: sidecars, legacyID: legacyID)

        let first = try sync.migrateEventsToSidecarFirst()
        #expect(first.migratedEvents.count == 1)

        // Second pass: nothing left to migrate.
        let second = try sync.migrateEventsToSidecarFirst()
        #expect(second.migratedEvents.isEmpty)
        #expect(second.rewrittenLinkIDs.isEmpty)
        // The new envelope is UUID-keyed AND has an eventKitID cell, so it
        // appears in `skipped`.
        #expect(second.skipped.count == 1)
    }

    /// Regression: manual (unlinked) events created via `createManualEvent`
    /// have a UUID-keyed sidecar but NO `eventKitID` cell. Migration must
    /// recognize them as post-pivot and leave them untouched. Without the
    /// fix, the migrator treats their UUID key as a legacy `eventIdentifier`,
    /// resolves it to nil, mints a fresh UUID, writes a bogus dead-pointer
    /// `eventKitID` cell, drops the cache cells, and falsely marks the event
    /// linked — silently destroying the manual event's data on every launch.
    @Test
    func migrationIsIdempotentForManualEvent() throws {
        let (sync, sidecars, _) = makeOrchestrator()
        let uuid = try sync.createManualEvent(
            title: "X",
            startDate: Date(timeIntervalSinceReferenceDate: 3_000_000),
            endDate: Date(timeIntervalSinceReferenceDate: 3_003_600),
            isAllDay: false,
            location: "Home"
        )
        let key = SidecarKey(kind: .event, id: uuid.uuidString)

        // Capture the BEFORE envelope so we can assert byte-for-byte equality.
        // SidecarEnvelope isn't Equatable; encode both as canonical JSON
        // (sorted keys) and compare the bytes.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let before = try encoder.encode(try #require(try sidecars.read(key)))

        let report = try sync.migrateEventsToSidecarFirst()
        #expect(report.migratedEvents.isEmpty)
        #expect(report.rewrittenLinkIDs.isEmpty)
        #expect(report.skipped.count == 1)
        // SidecarKey.event lowercases the id, so the skipped key is the
        // lowercased form of the UUID string.
        #expect(report.skipped.first == uuid.uuidString.lowercased())

        // AFTER envelope: the sidecar must be untouched.
        let after = try encoder.encode(try #require(try sidecars.read(key)))
        #expect(after == before)

        // And the projected event still reads as a manual (unlinked) event
        // with the original title.
        let projected = try #require(try sync.event(at: key))
        #expect(projected.id == uuid)
        #expect(projected.title == "X")
        #expect(projected.isLinked == false)
        #expect(projected.location == "Home")
    }

    // MARK: - Link rewrite

    @Test
    func migrationRewritesLinkEndpoints() throws {
        let (sync, sidecars, events) = makeOrchestrator()
        let legacyID = "legacy-event-id-link"
        let ekid = "ek-link-target"
        let event = Event(
            id: Event.stableID(forEventKitID: ekid),
            eventKitID: ekid,
            title: "Linked",
            startDate: Date(),
            endDate: Date().addingTimeInterval(60),
            isAllDay: false,
            location: nil,
            eventKitNotes: nil
        )
        _ = try _injectEventAndTranslation(into: events, event: event, legacy: legacyID)
        _ = try seedLegacyEnvelope(in: sidecars, legacyID: legacyID)

        // Seed a contact↔(.event, legacyID) link, BEFORE migration.
        let contactKey = SidecarKey(kind: .contact, id: UUID().uuidString)
        let eventEndpoint = SidecarKey(kind: .event, id: legacyID)
        let originalLink = try sync.addLink(from: contactKey, to: eventEndpoint, note: "attended")

        let report = try sync.migrateEventsToSidecarFirst()
        let migrated = try #require(report.migratedEvents.first)
        let newUUID = migrated.newUUID

        #expect(report.rewrittenLinkIDs == [originalLink.id])

        // Verify the link endpoint now points at the lowercased new UUID.
        let linkKey = SidecarKey.forLink(originalLink)
        let envelope = try #require(try sidecars.read(linkKey))
        let bCell = try #require(envelope.fields[Link.endpointBKey])
        let decoded = try #require(Link.decodeEndpoint(bCell.value))
        #expect(decoded.kind == .event)
        #expect(decoded.id == newUUID.uuidString.lowercased())

        // endpointA was a contact and should be unchanged.
        let aCell = try #require(envelope.fields[Link.endpointAKey])
        let decodedA = try #require(Link.decodeEndpoint(aCell.value))
        #expect(decodedA == contactKey)
    }

    @Test
    func migrationRewritesLinkEndpointWritesOnceWhenBothEndpointsMatch() throws {
        let (sync, sidecars, events) = makeOrchestrator()
        // Two legacy events on each side of the link.
        let legacyA = "legacy-a"
        let legacyB = "legacy-b"
        let ekA = "ek-a"
        let ekB = "ek-b"
        let evA = Event(
            id: Event.stableID(forEventKitID: ekA),
            eventKitID: ekA, title: "A",
            startDate: Date(), endDate: Date().addingTimeInterval(60),
            isAllDay: false, location: nil, eventKitNotes: nil
        )
        let evB = Event(
            id: Event.stableID(forEventKitID: ekB),
            eventKitID: ekB, title: "B",
            startDate: Date(), endDate: Date().addingTimeInterval(60),
            isAllDay: false, location: nil, eventKitNotes: nil
        )
        _ = try _injectEventAndTranslation(into: events, event: evA, legacy: legacyA)
        _ = try _injectEventAndTranslation(into: events, event: evB, legacy: legacyB)
        _ = try seedLegacyEnvelope(in: sidecars, legacyID: legacyA)
        _ = try seedLegacyEnvelope(in: sidecars, legacyID: legacyB)

        let originalLink = try sync.addLink(
            from: SidecarKey(kind: .event, id: legacyA),
            to: SidecarKey(kind: .event, id: legacyB),
            note: "both events"
        )

        let report = try sync.migrateEventsToSidecarFirst()
        // Each link rewritten exactly once — the helper records the link id
        // only once even when both endpoints match.
        #expect(report.rewrittenLinkIDs == [originalLink.id])

        // The map from old → new is uniquely determined by `migratedEvents`.
        var map: [String: UUID] = [:]
        for entry in report.migratedEvents {
            map[entry.oldExternalID] = entry.newUUID
        }
        let newA = try #require(map[legacyA])
        let newB = try #require(map[legacyB])

        let envelope = try #require(try sidecars.read(SidecarKey.forLink(originalLink)))
        let aDecoded = try #require(Link.decodeEndpoint(envelope.fields[Link.endpointAKey]!.value))
        let bDecoded = try #require(Link.decodeEndpoint(envelope.fields[Link.endpointBKey]!.value))
        #expect(aDecoded == SidecarKey(kind: .event, id: newA.uuidString))
        #expect(bDecoded == SidecarKey(kind: .event, id: newB.uuidString))
    }

    @Test
    func migrationLeavesUntouchedLinksAlone() throws {
        let (sync, sidecars, events) = makeOrchestrator()
        let legacyID = "legacy-rewrite-only-one"
        let ekid = "ek-only-one"
        let event = Event(
            id: Event.stableID(forEventKitID: ekid),
            eventKitID: ekid, title: "x",
            startDate: Date(), endDate: Date().addingTimeInterval(60),
            isAllDay: false, location: nil, eventKitNotes: nil
        )
        _ = try _injectEventAndTranslation(into: events, event: event, legacy: legacyID)
        _ = try seedLegacyEnvelope(in: sidecars, legacyID: legacyID)

        let contactA = SidecarKey(kind: .contact, id: UUID().uuidString)
        let contactB = SidecarKey(kind: .contact, id: UUID().uuidString)
        let unrelatedLink = try sync.addLink(from: contactA, to: contactB, note: "no events here")

        let report = try sync.migrateEventsToSidecarFirst()
        // The contact↔contact link should not be touched by the event
        // migration's link-endpoint rewrite.
        #expect(report.rewrittenLinkIDs.contains(unrelatedLink.id) == false)
    }

    // MARK: - Cache seeding branches

    @Test
    func migrationSeedsCacheFromEventKitWhenPresent() throws {
        let (sync, sidecars, events) = makeOrchestrator()
        let legacyID = "legacy-cache-seed"
        let ekid = "ek-cache-seed"
        let start = Date(timeIntervalSinceReferenceDate: 2_000_000)
        let end = start.addingTimeInterval(7200)
        let event = Event(
            id: Event.stableID(forEventKitID: ekid),
            eventKitID: ekid,
            title: "Real Title",
            startDate: start,
            endDate: end,
            isAllDay: true,
            location: "Conf",
            eventKitNotes: "ek note"
        )
        _ = try _injectEventAndTranslation(into: events, event: event, legacy: legacyID)
        _ = try seedLegacyEnvelope(in: sidecars, legacyID: legacyID)

        let report = try sync.migrateEventsToSidecarFirst()
        let migrated = try #require(report.migratedEvents.first)
        let newKey = SidecarKey(kind: .event, id: migrated.newUUID.uuidString)
        let envelope = try #require(try sidecars.read(newKey))

        #expect(cellStringValue(envelope.fields[GuessWhoSync.eventTitleCacheKey]!) == "Real Title")
        #expect(cellStringValue(envelope.fields[GuessWhoSync.eventLocationCacheKey]!) == "Conf")
        #expect(cellStringValue(envelope.fields[GuessWhoSync.eventNotesCacheKey]!) == "ek note")
        // isAllDay encoded as bool.
        let allDayCell = try #require(envelope.fields[GuessWhoSync.eventIsAllDayCacheKey])
        guard case .object(let inner) = allDayCell.value,
              case .bool(let flag) = inner[SidecarField.innerValueKey] ?? .null
        else {
            Issue.record("isAllDay cache cell shape wrong")
            return
        }
        #expect(flag == true)
    }

    @Test
    func migrationLeavesCacheEmptyWhenEventKitGone() throws {
        let (sync, sidecars, _) = makeOrchestrator()
        let legacyID = "legacy-cache-empty"
        _ = try seedLegacyEnvelope(in: sidecars, legacyID: legacyID)

        let report = try sync.migrateEventsToSidecarFirst()
        let migrated = try #require(report.migratedEvents.first)
        let newKey = SidecarKey(kind: .event, id: migrated.newUUID.uuidString)
        let envelope = try #require(try sidecars.read(newKey))
        #expect(envelope.fields[GuessWhoSync.eventTitleCacheKey] == nil)
        #expect(envelope.fields[GuessWhoSync.eventStartCacheKey] == nil)
        #expect(envelope.fields[GuessWhoSync.eventEndCacheKey] == nil)
        #expect(envelope.fields[GuessWhoSync.eventIsAllDayCacheKey] == nil)
        #expect(envelope.fields[GuessWhoSync.eventLocationCacheKey] == nil)
        #expect(envelope.fields[GuessWhoSync.eventNotesCacheKey] == nil)
    }

    // MARK: - Case-sensitivity of legacy IDs

    @Test
    func migrationPreservesCaseSensitiveLegacyIDs() throws {
        // Spec note: SidecarKey.init lowercases `.event` ids unconditionally
        // post-E1.4. In the in-memory store two SidecarKeys whose original
        // ids differ only in case collapse to a single key, so this test
        // exercises the lowercased-form contract: the legacy id is taken
        // verbatim from `key.id` (already lowercased), fed to
        // `fetch(legacyEventIdentifier:)`, and used as the map key.
        let (sync, sidecars, events) = makeOrchestrator()
        let legacyOriginalCase = "AbC123"
        let lowercased = legacyOriginalCase.lowercased()
        let ekid = "ek-case-resolved"
        let event = Event(
            id: Event.stableID(forEventKitID: ekid),
            eventKitID: ekid, title: "case-test",
            startDate: Date(), endDate: Date().addingTimeInterval(60),
            isAllDay: false, location: nil, eventKitNotes: nil
        )
        // Register both the original-case and lowercased translations: the
        // EventKit-mock's `event(withIdentifier:)` analog is case-sensitive,
        // and migration's input may be either case depending on which
        // listKeys path produced the key.
        _ = try _injectEventAndTranslation(into: events, event: event, legacy: legacyOriginalCase)
        events.setLegacyTranslation(lowercased, to: ekid)

        // Seed with the original-case id — InMemorySidecarStore stores it
        // under the lowercased key because SidecarKey.init lowercases.
        _ = try seedLegacyEnvelope(in: sidecars, legacyID: legacyOriginalCase)

        let report = try sync.migrateEventsToSidecarFirst()
        let migrated = try #require(report.migratedEvents.first)
        // The remembered legacy id is whatever the store handed back via
        // `allKeys()` — in this setup the lowercased form.
        #expect(migrated.oldExternalID == lowercased)

        let newKey = SidecarKey(kind: .event, id: migrated.newUUID.uuidString)
        let envelope = try #require(try sidecars.read(newKey))
        let ekidCell = try #require(envelope.fields[GuessWhoSync.eventKitIDCellKey])
        #expect(cellStringValue(ekidCell) == ekid)
    }

    // MARK: - Cross-device contract surface

    @Test
    func crossDeviceTwoUUIDsForSameEventKitID() throws {
        // Simulate post-migration state on two devices that independently
        // minted UUIDs for the same `eventKitID`. The orchestrator's
        // `eventUUID(forEventKitID:)` must return the lex-min UUID per the
        // E1.7 contract (already covered by phase 2 tests; reproved here
        // against a hand-built migration outcome).
        let (sync, sidecars, _) = makeOrchestrator()
        let sharedEKID = "ek-shared-across-devices"
        let uuidA = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let uuidB = try #require(UUID(uuidString: "ffffffff-ffff-ffff-ffff-ffffffffffff"))

        // Build two UUID-keyed envelopes pointing at the same eventKitID.
        for uuid in [uuidA, uuidB] {
            let key = SidecarKey(kind: .event, id: uuid.uuidString)
            let now = Date()
            let inner = SidecarField.makeInnerValue(
                field: GuessWhoSync.eventKitIDCellKey,
                type: .note,
                value: .string(sharedEKID),
                createdAt: now
            )
            let fields: [String: SidecarCell] = [
                GuessWhoSync.eventKitIDCellKey: SidecarCell(
                    value: inner,
                    modifiedAt: now,
                    modifiedBy: "test"
                )
            ]
            let envelope = SidecarEnvelope(
                schemaVersion: 1,
                entityID: key.id,
                fields: fields
            )
            try sidecars.write(envelope, at: key)
        }

        // Idempotent migration: both are already UUID-keyed and have the
        // cell — both should land in `skipped`.
        let report = try sync.migrateEventsToSidecarFirst()
        #expect(report.migratedEvents.isEmpty)
        #expect(report.skipped.count == 2)

        // Lex-min contract: returns the smaller UUID.
        let resolved = try #require(try sync.eventUUID(forEventKitID: sharedEKID))
        #expect(resolved == uuidA)
    }

    // MARK: - Helpers

    /// Wedge an Event into the in-memory store under its eventKitID and
    /// register the legacy → ekid translation. Returns the event for
    /// chaining.
    @discardableResult
    private func _injectEventAndTranslation(
        into events: InMemoryEventStore,
        event: Event,
        legacy: String
    ) throws -> (Event, String) {
        // The in-memory store's only "create-with-known-id" path is the
        // public initializer's seed list, so use that round-tripped here
        // via createEvent + a follow-up rewrite is awkward. Instead we
        // expose enough through the test surface to do the same job: use
        // the EKID mapping plus a one-shot injection.
        try events._injectForTest(event: event)
        guard let ekid = event.eventKitID else {
            Issue.record("event missing eventKitID — invalid test fixture")
            return (event, "")
        }
        events.setLegacyTranslation(legacy, to: ekid)
        return (event, ekid)
    }
}
