#if canImport(EventKit)
import EventKit
import Foundation
import Testing
@testable import GuessWhoSync
import GuessWhoSyncTesting

/// EventKit can hold several copies of one event under one `eventKitID` (for
/// example one calendar file imported into two calendars). These pin that
/// every read merges the copies of an
/// occurrence into ONE `Event` whose primary copy is chosen deterministically
/// and whose `calendarIDs` names every copy's calendar — so hiding one of the
/// calendars can never decide the row by EventKit's enumeration order — and
/// that the window batch, the single-event lookup, and the projections built
/// on them all agree.
@Suite("EventKit calendar copies")
struct EventCalendarCopiesTests {
    private static let start = Date(timeIntervalSince1970: 1_000_000)
    private static let window = DateInterval(start: start.addingTimeInterval(-3_600), duration: 7_200)
    private static let sharedID = "shared-event"

    private final class UpdateCapture: @unchecked Sendable {
        private let lock = NSLock()
        private let writableEvents: [EKEvent]
        private var requestedID: String?
        private var savedSameObjects = false
        private var savedTitles: [String] = []
        private var savedStarts: [Date] = []

        init(writableEvents: [EKEvent]) {
            self.writableEvents = writableEvents
        }

        func events(for eventKitID: String) -> [EKEvent] {
            lock.lock()
            defer { lock.unlock() }
            requestedID = eventKitID
            return writableEvents
        }

        func recordSave(_ events: [EKEvent]) {
            lock.lock()
            defer { lock.unlock() }
            savedSameObjects = Set(events.map(ObjectIdentifier.init))
                == Set(writableEvents.map(ObjectIdentifier.init))
            savedTitles = events.map { $0.title }
            savedStarts = events.map { $0.startDate }
        }

        func snapshot() -> (
            requestedID: String?,
            savedSameObjects: Bool,
            savedTitles: [String],
            savedStarts: [Date]
        ) {
            lock.lock()
            defer { lock.unlock() }
            return (requestedID, savedSameObjects, savedTitles, savedStarts)
        }
    }

    /// One EventKit copy, shaped as `toEvent` stamps it: `calendarIDs` lists
    /// only the copy's own calendar.
    private static func copy(
        ekid: String = sharedID,
        calendarID: String?,
        calendarName: String?,
        start: Date = start,
        emails: [String] = []
    ) -> Event {
        Event(
            id: Event.stableID(forEventKitID: ekid),
            eventKitID: ekid,
            title: "Planning",
            startDate: start,
            endDate: start.addingTimeInterval(1_800),
            attendees: emails.map { EventAttendee(name: $0, email: $0) },
            calendarID: calendarID,
            calendarIDs: calendarID.map { [$0] },
            calendarName: calendarName
        )
    }

    // "cal-family" sorts before "cal-mine", so the Family copy is primary.
    private static let family = copy(calendarID: "cal-family", calendarName: "Family")
    private static let mine = copy(calendarID: "cal-mine", calendarName: "Mine")
    private static let other = copy(ekid: "other-event", calendarID: "cal-mine", calendarName: "Mine")

    /// The merged Family + Mine occurrence every read must produce.
    private static func expectMergedSharedCopy(_ event: Event?) {
        #expect(event?.eventKitID == sharedID)
        #expect(event?.calendarID == "cal-family")
        #expect(event?.calendarName == "Family")
        #expect(event?.calendarIDs == ["cal-family", "cal-mine"])
        #expect(event?.allCalendarIDs == ["cal-family", "cal-mine"])
    }

    // MARK: - Raw batch merge

    @Test("The batch merges the copies of one occurrence the same way in either order")
    func batchMergesCopiesWhateverTheEnumerationOrder() {
        let forward = EKEventStoreAdapter.collapsingCalendarCopies([Self.mine, Self.family])
        let reversed = EKEventStoreAdapter.collapsingCalendarCopies([Self.family, Self.mine])

        #expect(forward.count == 1)
        #expect(forward == reversed)
        Self.expectMergedSharedCopy(forward.first)
    }

    @Test("The batch keeps each occurrence of a recurring event, each with every copy's calendar")
    func batchKeepsRecurringOccurrencesApart() {
        let nextStart = Self.start.addingTimeInterval(86_400)
        let batch = [
            Self.mine,
            Self.copy(calendarID: "cal-mine", calendarName: "Mine", start: nextStart),
            Self.family,
            Self.copy(calendarID: "cal-family", calendarName: "Family", start: nextStart),
        ]

        let collapsed = EKEventStoreAdapter.collapsingCalendarCopies(batch)

        #expect(collapsed.map(\.startDate) == [Self.start, nextStart])
        #expect(collapsed.allSatisfy { $0.calendarIDs == ["cal-family", "cal-mine"] })
        #expect(collapsed.allSatisfy { $0.calendarID == "cal-family" })
    }

    @Test("A copy re-seen across a chunk seam collapses to that copy, unchanged")
    func batchCollapsesAChunkSeamRepeat() {
        #expect(EKEventStoreAdapter.collapsingCalendarCopies([Self.mine, Self.mine]) == [Self.mine])
    }

    @Test("Lone copies pass through unchanged, in first-seen order")
    func loneCopiesPassThroughUnchanged() {
        // No `calendarIDs`: a lone copy is not rewritten, so it stays nil.
        var bare = Self.copy(ekid: "bare-event", calendarID: "cal-work", calendarName: "Work")
        bare.calendarIDs = nil
        let batch = [Self.other, bare]

        #expect(EKEventStoreAdapter.collapsingCalendarCopies(batch) == batch)
    }

    @Test("A copy whose calendar can't be resolved never becomes the primary copy")
    func copyWithoutCalendarNeverWinsPrimary() {
        let unresolved = Self.copy(calendarID: nil, calendarName: nil)

        for batch in [[unresolved, Self.mine], [Self.mine, unresolved]] {
            let merged = EKEventStoreAdapter.collapsingCalendarCopies(batch)
            #expect(merged.count == 1)
            #expect(merged.first?.calendarID == "cal-mine")
            #expect(merged.first?.calendarIDs == ["cal-mine"])
        }
    }

    // MARK: - Single-event lookup

    @Test("The single-event lookup merges copies exactly as the batch does")
    func singleLookupMatchesTheBatch() {
        let batch = EKEventStoreAdapter.collapsingCalendarCopies([Self.family, Self.mine]).first

        #expect(EKEventStoreAdapter.singleEvent(fromCopies: [Self.mine, Self.family]) == batch)
        #expect(EKEventStoreAdapter.singleEvent(fromCopies: [Self.family, Self.mine]) == batch)
        #expect(EKEventStoreAdapter.singleEvent(fromCopies: []) == nil)
    }

    @Test("The single-event lookup merges only copies of the primary copy's occurrence")
    func singleLookupMergesOnlyThePrimaryOccurrence() {
        // One series per calendar, starting on different days: they are
        // different occurrences, so the batch would not merge them either.
        let laterSeries = Self.copy(
            calendarID: "cal-mine", calendarName: "Mine", start: Self.start.addingTimeInterval(86_400)
        )

        let single = EKEventStoreAdapter.singleEvent(fromCopies: [laterSeries, Self.family])

        #expect(single == Self.family)
    }

    // MARK: - Adapter wiring

    private func makeAdapter(
        batch: [Event],
        copiesByID: [String: [Event]]
    ) -> EKEventStoreAdapter {
        EKEventStoreAdapter(
            notificationCenter: NotificationCenter(),
            fetchEventsWork: { _, _ in batch },
            fetchEventCopiesWork: { _, eventKitID in copiesByID[eventKitID] ?? [] },
            authorizationStatusWork: { .authorized }
        )
    }

    private func makeSharedAdapter() -> EKEventStoreAdapter {
        makeAdapter(
            batch: [Self.mine, Self.other, Self.family],
            copiesByID: [Self.sharedID: [Self.mine, Self.family], "other-event": [Self.other]]
        )
    }

    @Test("The adapter's window read and single-event lookup return the same merged event")
    func adapterWindowReadAndSingleLookupAgree() throws {
        let adapter = makeSharedAdapter()

        let batch = try adapter.fetchEvents(in: Self.window)
        let single = try adapter.fetch(eventKitID: Self.sharedID)

        #expect(batch.map(\.eventKitID) == [Self.sharedID, "other-event"])
        Self.expectMergedSharedCopy(single)
        #expect(batch.first == single)
        #expect(try adapter.fetch(eventKitID: "missing-event") == nil)
    }

    @Test("The attendee lookup sees one merged event, not one per copy")
    func attendeeLookupSeesOneMergedEvent() throws {
        let adapter = makeAdapter(
            batch: [
                Self.copy(calendarID: "cal-mine", calendarName: "Mine", emails: ["a@x.com"]),
                Self.copy(calendarID: "cal-family", calendarName: "Family", emails: ["a@x.com"]),
            ],
            copiesByID: [:]
        )

        let result = try adapter.eventsWithAttendee(matchingEmails: ["a@x.com"], in: Self.window, limit: 10)

        #expect(result.count == 1)
        Self.expectMergedSharedCopy(result.first)
    }

    @Test("The writable primary calendar uses the same deterministic ordering as reads")
    func writablePrimaryCalendarMatchesReadOrdering() {
        #expect(EKEventStoreAdapter.primaryCalendarCopyIndex(["cal-b", "cal-a", nil]) == 1)
        #expect(EKEventStoreAdapter.primaryCalendarCopyIndex([nil, "cal-b", "cal-a"]) == 2)
        #expect(EKEventStoreAdapter.primaryCalendarCopyIndex([nil, nil]) == 0)
        #expect(EKEventStoreAdapter.primaryCalendarCopyIndex([]) == nil)
    }

    @Test("updateEvent edits and saves every calendar copy of the primary occurrence")
    func updateEventUsesEveryCopyFromPrimaryOccurrenceResolver() throws {
        let store = EKEventStore()
        let writableA = EKEvent(eventStore: store)
        writableA.title = "Old title A"
        writableA.startDate = Self.start
        writableA.endDate = Self.start.addingTimeInterval(900)
        let writableB = EKEvent(eventStore: store)
        writableB.title = "Old title B"
        writableB.startDate = Self.start
        writableB.endDate = Self.start.addingTimeInterval(900)
        let capture = UpdateCapture(writableEvents: [writableA, writableB])
        let newStart = Self.start.addingTimeInterval(300)
        let adapter = EKEventStoreAdapter(
            store: store,
            notificationCenter: NotificationCenter(),
            fetchEventsWork: { _, _ in [] },
            fetchEventsForUpdateWork: { _, eventKitID in capture.events(for: eventKitID) },
            saveEventsWork: { _, events in capture.recordSave(events) },
            authorizationStatusWork: { .authorized }
        )

        try adapter.updateEvent(
            eventKitID: Self.sharedID,
            title: "Edited title",
            startDate: newStart,
            endDate: newStart.addingTimeInterval(1_800),
            isAllDay: false,
            location: "New room"
        )

        let result = capture.snapshot()
        #expect(result.requestedID == Self.sharedID)
        #expect(result.savedSameObjects)
        #expect(result.savedTitles == ["Edited title", "Edited title"])
        #expect(result.savedStarts == [newStart, newStart])
    }

    // MARK: - Projections built on the adapter

    private func makeSync(adapter: EKEventStoreAdapter) -> GuessWhoSync {
        GuessWhoSync(
            contacts: InMemoryContactStore(),
            events: adapter,
            sidecars: InMemorySidecarStore(),
            deviceID: "device-A"
        )
    }

    @Test("An unadopted window row carries every copy's calendar")
    func eventsWindowEphemeralRowCarriesEveryCopysCalendar() throws {
        let sync = makeSync(adapter: makeSharedAdapter())

        let rows = try sync.eventsWindow(from: Self.window.start, to: Self.window.end)

        let row = try #require(rows.first { $0.eventKitID == Self.sharedID })
        #expect(rows.filter { $0.eventKitID == Self.sharedID }.count == 1)
        #expect(row.id == Event.stableID(forEventKitID: Self.sharedID))
        Self.expectMergedSharedCopy(row)
    }

    @Test("A linked event's window row, single read, and delta read agree on its calendars")
    func linkedEventProjectionsAgree() throws {
        let sync = makeSync(adapter: makeSharedAdapter())
        let sidecarID = try sync.linkEvent(
            toEventKitID: Self.sharedID,
            snapshot: Event(
                eventKitID: Self.sharedID,
                title: "Cached title",
                startDate: Self.start,
                endDate: Self.start.addingTimeInterval(1_800)
            )
        )
        let key = SidecarKey(kind: .event, id: sidecarID.uuidString)

        let windowRow = try #require(
            try sync.eventsWindow(from: Self.window.start, to: Self.window.end)
                .first { $0.eventKitID == Self.sharedID }
        )
        let single = try sync.event(at: key)
        let delta = try sync.eventForWatcherDelta(
            at: key, from: Self.window.start, to: Self.window.end, includeEventKit: true
        )

        #expect(windowRow.id == sidecarID)
        #expect(windowRow.title == "Planning")
        Self.expectMergedSharedCopy(windowRow)
        #expect(single == windowRow)
        #expect(delta == windowRow)
    }
}
#endif
