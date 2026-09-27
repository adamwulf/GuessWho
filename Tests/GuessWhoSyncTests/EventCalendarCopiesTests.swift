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
        emails: [String] = [],
        allowsContentModifications: Bool? = nil
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
            calendarAllowsContentModifications: allowsContentModifications,
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

    @Test("The single-event lookup unions calendars even when copies have drifted")
    func singleLookupUnionsCalendarsAcrossDriftedCopies() {
        let laterSeries = Self.copy(
            calendarID: "cal-mine", calendarName: "Mine", start: Self.start.addingTimeInterval(86_400)
        )

        let single = EKEventStoreAdapter.singleEvent(fromCopies: [laterSeries, Self.family])

        #expect(single?.calendarID == "cal-family")
        #expect(single?.startDate == Self.start)
        #expect(single?.calendarIDs == ["cal-family", "cal-mine"])
    }

    @Test("The representative prefers a writable copy over a smaller read-only calendar")
    func representativePrefersWritableCopy() {
        let readOnlyFamily = Self.copy(
            calendarID: "cal-family",
            calendarName: "Family",
            allowsContentModifications: false
        )
        let writableMine = Self.copy(
            calendarID: "cal-mine",
            calendarName: "Mine",
            allowsContentModifications: true
        )

        let representative = EKEventStoreAdapter.singleEvent(
            fromCopies: [readOnlyFamily, writableMine]
        )

        #expect(representative?.calendarID == "cal-mine")
        #expect(representative?.calendarName == "Mine")
        #expect(representative?.calendarIDs == ["cal-family", "cal-mine"])
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
        let later = Self.start.addingTimeInterval(300)
        #expect(Event.primaryCalendarCopyIndex(
            calendarIDs: ["cal-b", "cal-a", nil],
            startDates: [Self.start, later, Self.start]
        ) == 1)
        #expect(Event.primaryCalendarCopyIndex(
            calendarIDs: [nil, "cal-b", "cal-a"],
            startDates: [Self.start, Self.start, later]
        ) == 2)
        #expect(Event.primaryCalendarCopyIndex(
            calendarIDs: [nil, nil],
            startDates: [later, Self.start]
        ) == 1)
        #expect(Event.primaryCalendarCopyIndex(
            calendarIDs: ["cal-a", "cal-b"],
            startDates: [Self.start, Self.start],
            allowsContentModifications: [false, true]
        ) == 1)
        #expect(Event.primaryCalendarCopyIndex(calendarIDs: [], startDates: []) == nil)
    }

    @Test("The update selection prefers writable copies and rejects an all-read-only event")
    func updateSelectionRespectsWritabilityAndOccurrence() throws {
        let later = Self.start.addingTimeInterval(300)

        #expect(try EKEventStoreAdapter.writablePrimaryOccurrenceIndices(
            calendarIDs: ["cal-b", "cal-a", "cal-c"],
            startDates: [Self.start, Self.start, Self.start],
            isWritable: [true, true, false]
        ) == [1, 0])
        #expect(try EKEventStoreAdapter.writablePrimaryOccurrenceIndices(
            calendarIDs: ["cal-a", "cal-b"],
            startDates: [Self.start, later],
            isWritable: [true, true]
        ) == [0])
        #expect(try EKEventStoreAdapter.writablePrimaryOccurrenceIndices(
            calendarIDs: ["cal-a", "cal-b"],
            startDates: [Self.start, Self.start],
            isWritable: [false, true]
        ) == [1])
        #expect(throws: EventStoreError.noWritableCalendar) {
            try EKEventStoreAdapter.writablePrimaryOccurrenceIndices(
                calendarIDs: ["cal-a", "cal-b"],
                startDates: [Self.start, Self.start],
                isWritable: [false, false]
            )
        }
    }

    @Test("The writable lookup deduplicates a legacy event repeated by the canonical lookup")
    func writableLookupDeduplicatesObjects() {
        let store = EKEventStore()
        let first = EKEvent(eventStore: store)
        let second = EKEvent(eventStore: store)

        let unique = EKEventStoreAdapter.uniqueEventKitCopies([first, first, second, first])

        #expect(unique.count == 2)
        #expect(unique[0] === first)
        #expect(unique[1] === second)
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

    @Test("A recurring row prefers an occurrence whose start is inside the window")
    func eventsWindowPrefersInWindowOccurrenceOverOverlap() throws {
        let from = Self.start
        let to = from.addingTimeInterval(3_600)
        let overlap = Self.copy(
            calendarID: "cal-mine",
            calendarName: "Mine",
            start: from.addingTimeInterval(-900)
        )
        let inWindow = Self.copy(
            calendarID: "cal-mine",
            calendarName: "Mine",
            start: from.addingTimeInterval(300)
        )
        let sync = makeSync(adapter: makeAdapter(batch: [inWindow, overlap], copiesByID: [:]))

        let rows = try sync.eventsWindow(from: from, to: to)

        #expect(rows.count == 1)
        #expect(rows.first?.startDate == inWindow.startDate)
    }

    @Test("A recurring row uses the latest occurrence that starts inside the window")
    func eventsWindowUsesLatestInWindowOccurrence() throws {
        let from = Self.start
        let to = from.addingTimeInterval(3_600)
        let earlier = Self.copy(
            calendarID: "cal-mine",
            calendarName: "Mine",
            start: from.addingTimeInterval(300)
        )
        let later = Self.copy(
            calendarID: "cal-mine",
            calendarName: "Mine",
            start: from.addingTimeInterval(600)
        )
        let sync = makeSync(adapter: makeAdapter(batch: [later, earlier], copiesByID: [:]))

        let rows = try sync.eventsWindow(from: from, to: to)

        #expect(rows.count == 1)
        #expect(rows.first?.startDate == later.startDate)
    }

    @Test("Window membership wins before writability when copies straddle the boundary")
    func eventsWindowPrefersInWindowReadOnlyCopyOverWritableOverlap() throws {
        let from = Self.start
        let to = from.addingTimeInterval(3_600)
        let writableOverlap = Self.copy(
            calendarID: "cal-z",
            calendarName: "Writable",
            start: from.addingTimeInterval(-900),
            allowsContentModifications: true
        )
        let readOnlyInWindow = Self.copy(
            calendarID: "cal-a",
            calendarName: "Read Only",
            start: from.addingTimeInterval(300),
            allowsContentModifications: false
        )
        let sync = makeSync(adapter: makeAdapter(
            batch: [writableOverlap, readOnlyInWindow],
            copiesByID: [:]
        ))

        let row = try #require(sync.eventsWindow(from: from, to: to).first)

        #expect(row.startDate == readOnlyInWindow.startDate)
        #expect(row.calendarID == "cal-a")
        #expect(row.calendarIDs == ["cal-a", "cal-z"])
    }

    @Test("A linked event's full and delta reads agree when calendar copies have drifted")
    func linkedEventProjectionsAgreeAcrossDriftedCopies() throws {
        let laterMine = Self.copy(
            calendarID: "cal-mine",
            calendarName: "Mine",
            start: Self.start.addingTimeInterval(300)
        )
        let adapter = makeAdapter(
            batch: [laterMine, Self.family],
            copiesByID: [Self.sharedID: [laterMine, Self.family]]
        )
        let sync = makeSync(adapter: adapter)
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

    @Test("A linked event's full and delta reads agree when one copy moved outside the window")
    func linkedEventProjectionsAgreeAcrossWindowEdge() throws {
        let from = Self.start
        let to = from.addingTimeInterval(3_600)
        let readOnlyInWindow = Self.copy(
            calendarID: "cal-a",
            calendarName: "Read Only",
            start: from.addingTimeInterval(300),
            allowsContentModifications: false
        )
        let writableOutside = Self.copy(
            calendarID: "cal-z",
            calendarName: "Writable",
            start: to.addingTimeInterval(3_600),
            allowsContentModifications: true
        )
        // The window batch contains only the overlapping copy; the direct
        // lookup can still see both. Full and delta projections must use the
        // window batch and therefore agree on the in-window row.
        let adapter = makeAdapter(
            batch: [readOnlyInWindow],
            copiesByID: [Self.sharedID: [writableOutside, readOnlyInWindow]]
        )
        let sync = makeSync(adapter: adapter)
        let sidecarID = try sync.linkEvent(
            toEventKitID: Self.sharedID,
            snapshot: writableOutside
        )
        let key = SidecarKey(kind: .event, id: sidecarID.uuidString)

        let windowRow = try #require(
            try sync.eventsWindow(from: from, to: to).first { $0.eventKitID == Self.sharedID }
        )
        let delta = try sync.eventForWatcherDelta(
            at: key,
            from: from,
            to: to,
            includeEventKit: true
        )

        #expect(windowRow.startDate == readOnlyInWindow.startDate)
        #expect(delta == windowRow)
    }
}
#endif
