#if canImport(EventKit)
import EventKit
import Foundation
import Testing
@testable import GuessWhoSync
import GuessWhoSyncTesting

@Suite("EKEventStoreAdapter window coalescing")
struct EKEventStoreAdapterCoalescingTests {
    private func makeAdapter(
        center: NotificationCenter = NotificationCenter(),
        spy: BlockingEventWindowFetchSpy
    ) -> EKEventStoreAdapter {
        EKEventStoreAdapter(
            notificationCenter: center,
            cacheLifetime: 60,
            fetchEventsWork: { _, interval in spy.fetch(interval: interval) },
            authorizationStatusWork: { .authorized }
        )
    }

    private func window(start: TimeInterval = 1_000, duration: TimeInterval = 3_600) -> DateInterval {
        DateInterval(
            start: Date(timeIntervalSince1970: start),
            duration: duration
        )
    }

    @Test
    func concurrentIdenticalWindowsShareOneUnderlyingEventKitQuery() async throws {
        let interval = window()
        let spy = BlockingEventWindowFetchSpy(blockFirstFetch: true)
        let adapter = makeAdapter(spy: spy)

        let first = Task.detached { try adapter.fetchEvents(in: interval) }
        #expect(spy.waitForFetchCount(1))

        let second = Task.detached { try adapter.fetchEvents(in: interval) }
        var joined = false
        for _ in 0..<1_000 {
            if adapter.inFlightWindowCallerCountForTesting(interval) == 2 {
                joined = true
                break
            }
            await Task.yield()
        }
        #expect(joined)

        spy.releaseFirstFetch()
        let firstResult = try await first.value
        let secondResult = try await second.value

        #expect(spy.fetchCount == 1)
        #expect(firstResult == secondResult)
        #expect(firstResult.first?.title == "Snapshot 1")
    }

    @Test
    func eventStoreChangedBetweenIdenticalFetchesForcesFreshQuery() throws {
        let interval = window()
        let center = NotificationCenter()
        let spy = BlockingEventWindowFetchSpy()
        let adapter = makeAdapter(center: center, spy: spy)

        let first = try adapter.fetchEvents(in: interval)
        let cached = try adapter.fetchEvents(in: interval)
        #expect(spy.fetchCount == 1)
        #expect(first == cached)

        center.post(name: .EKEventStoreChanged, object: nil)

        let fresh = try adapter.fetchEvents(in: interval)
        #expect(spy.fetchCount == 2)
        #expect(fresh.first?.title == "Snapshot 2")
        #expect(fresh != first)
    }

    @Test
    func calendarAccessTransitionInvalidatesAndNeverCachesNoAccessResult() throws {
        let interval = window()
        let spy = BlockingEventWindowFetchSpy()
        let authorization = AuthorizationStatusBox(.authorized)
        let adapter = EKEventStoreAdapter(
            notificationCenter: NotificationCenter(),
            cacheLifetime: 60,
            fetchEventsWork: { _, interval in spy.fetch(interval: interval) },
            authorizationStatusWork: { authorization.value }
        )

        _ = try adapter.fetchEvents(in: interval)
        _ = try adapter.fetchEvents(in: interval)
        #expect(spy.fetchCount == 1)

        authorization.value = .denied
        let deniedResult = try adapter.fetchEvents(in: interval)
        #expect(spy.fetchCount == 2)
        #expect(deniedResult.first?.title == "Snapshot 2")

        // The denied result was deliberately not cached. Restoring access also
        // advances the generation, so the next read is a third fresh query.
        authorization.value = .authorized
        let restoredResult = try adapter.fetchEvents(in: interval)
        #expect(spy.fetchCount == 3)
        #expect(restoredResult.first?.title == "Snapshot 3")
    }

    @Test
    func differentWindowsAreNeverShared() async throws {
        let firstWindow = window()
        let secondWindow = window(start: 10_000)
        let spy = BlockingEventWindowFetchSpy(blockFirstFetch: true)
        let adapter = makeAdapter(spy: spy)

        let first = Task.detached { try adapter.fetchEvents(in: firstWindow) }
        #expect(spy.waitForFetchCount(1))
        let second = Task.detached { try adapter.fetchEvents(in: secondWindow) }

        // A differently-keyed request starts immediately; it does not wait on
        // or consume the first window's active flight.
        #expect(spy.waitForFetchCount(2))
        spy.releaseFirstFetch()
        _ = try await first.value
        _ = try await second.value

        #expect(spy.fetchCount == 2)
        #expect(Set(spy.intervals) == Set([firstWindow, secondWindow]))
    }

    @Test
    func invalidationDuringFlightDiscardsRacedResultAndRetriesFresh() async throws {
        let interval = window()
        let center = NotificationCenter()
        let spy = BlockingEventWindowFetchSpy(blockFirstFetch: true)
        let adapter = makeAdapter(center: center, spy: spy)

        let preChangeCaller = Task.detached { try adapter.fetchEvents(in: interval) }
        #expect(spy.waitForFetchCount(1))

        center.post(name: .EKEventStoreChanged, object: nil)
        let postChangeCaller = Task.detached { try adapter.fetchEvents(in: interval) }
        #expect(spy.waitForFetchCount(2))

        spy.releaseFirstFetch()
        let preChangeResult = try await preChangeCaller.value
        let postChangeResult = try await postChangeCaller.value

        // The first query's Snapshot 1 completed after invalidation, so it was
        // discarded. Even its original caller joins/uses the generation-1
        // fetch and no caller returns pre-change data.
        #expect(spy.fetchCount == 2)
        #expect(preChangeResult.first?.title == "Snapshot 2")
        #expect(postChangeResult.first?.title == "Snapshot 2")
    }

    @Test
    func cachedRawBatchLeavesSidecarOverlayProjectionUnchanged() throws {
        let interval = window()
        let linkedID = "linked-event"
        let live = Event(
            id: Event.stableID(forEventKitID: linkedID),
            eventKitID: linkedID,
            title: "Live title",
            startDate: interval.start.addingTimeInterval(60),
            endDate: interval.start.addingTimeInterval(120),
            location: "Live location",
            eventKitNotes: "Live notes"
        )
        let ephemeralID = "ephemeral-event"
        let ephemeral = Event(
            id: Event.stableID(forEventKitID: ephemeralID),
            eventKitID: ephemeralID,
            title: "Ephemeral",
            startDate: interval.start.addingTimeInterval(180),
            endDate: interval.start.addingTimeInterval(240)
        )
        let spy = BlockingEventWindowFetchSpy(events: [live, ephemeral])
        let adapter = makeAdapter(spy: spy)
        let sidecars = InMemorySidecarStore()
        let sync = GuessWhoSync(
            contacts: InMemoryContactStore(),
            events: adapter,
            sidecars: sidecars,
            deviceID: "device-A"
        )
        let sidecarID = try sync.linkEvent(
            toEventKitID: linkedID,
            snapshot: Event(
                eventKitID: linkedID,
                title: "Cached title",
                startDate: live.startDate,
                endDate: live.endDate,
                location: "Cached location"
            )
        )

        let cold = try sync.eventsWindow(from: interval.start, to: interval.end)
        let warm = try sync.eventsWindow(from: interval.start, to: interval.end)

        #expect(spy.fetchCount == 1)
        #expect(cold == warm)
        let projected = try #require(warm.first { $0.eventKitID == linkedID })
        #expect(projected.id == sidecarID)
        #expect(projected.title == "Live title")
        #expect(projected.location == "Live location")
        #expect(projected.eventKitNotes == "Live notes")
        #expect(warm.contains { $0.eventKitID == ephemeralID })
    }
}

/// Thread-safe fake for the injected raw EventKit window operation. The first
/// invocation can be parked while another caller either joins it (same window)
/// or starts independently (different window/new invalidation generation).
private final class BlockingEventWindowFetchSpy: @unchecked Sendable {
    private let condition = NSCondition()
    private let blockFirstFetch: Bool
    private let fixedEvents: [Event]?
    private var firstFetchReleased = false
    private var _fetchCount = 0
    private var _intervals: [DateInterval] = []

    init(blockFirstFetch: Bool = false, events: [Event]? = nil) {
        self.blockFirstFetch = blockFirstFetch
        self.fixedEvents = events
    }

    func fetch(interval: DateInterval) -> [Event] {
        condition.lock()
        _fetchCount += 1
        let invocation = _fetchCount
        _intervals.append(interval)
        condition.broadcast()
        while blockFirstFetch && invocation == 1 && !firstFetchReleased {
            condition.wait()
        }
        condition.unlock()

        if let fixedEvents { return fixedEvents }
        return [Event(
            eventKitID: "snapshot-\(invocation)",
            title: "Snapshot \(invocation)",
            startDate: interval.start.addingTimeInterval(60),
            endDate: interval.start.addingTimeInterval(120)
        )]
    }

    func waitForFetchCount(_ expected: Int) -> Bool {
        let deadline = Date().addingTimeInterval(2)
        condition.lock()
        defer { condition.unlock() }
        while _fetchCount < expected {
            guard condition.wait(until: deadline) else { return false }
        }
        return true
    }

    func releaseFirstFetch() {
        condition.lock()
        firstFetchReleased = true
        condition.broadcast()
        condition.unlock()
    }

    var fetchCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return _fetchCount
    }

    var intervals: [DateInterval] {
        condition.lock()
        defer { condition.unlock() }
        return _intervals
    }
}

private final class AuthorizationStatusBox: @unchecked Sendable {
    private let lock = NSLock()
    private var status: StoreAuthorizationStatus

    init(_ status: StoreAuthorizationStatus) {
        self.status = status
    }

    var value: StoreAuthorizationStatus {
        get {
            lock.lock()
            defer { lock.unlock() }
            return status
        }
        set {
            lock.lock()
            status = newValue
            lock.unlock()
        }
    }
}
#endif
