import Foundation
import Testing
@testable import GuessWhoSync
import GuessWhoSyncTesting

@Suite("GuideSidecar")
struct GuideSidecarTests {
    private func makeOrchestrator(
        deviceID: String = "device-A"
    ) -> (GuessWhoSync, InMemorySidecarStore) {
        let contacts = InMemoryContactStore()
        let events = InMemoryEventStore()
        let sidecars = InMemorySidecarStore()
        let sync = GuessWhoSync(
            contacts: contacts,
            events: events,
            sidecars: sidecars,
            deviceID: deviceID
        )
        return (sync, sidecars)
    }

    private var sampleSnapshot: MapsGuideURL.Snapshot {
        MapsGuideURL.Snapshot(
            name: "Berlin",
            entries: [
                MapsGuideURL.Entry(mapsPlaceID: "ID09B4D36386DC9DA"),
                MapsGuideURL.Entry(
                    address: "Samariterstraße 31, Friedrichshain, 10247 Berlin, Germany",
                    latitude: 52.5169198,
                    longitude: 13.4651753
                ),
                MapsGuideURL.Entry(mapsPlaceID: "I2C0916C36239E325"),
            ]
        )
    }

    private func makeCountingOrchestrator(
        notificationCenter: NotificationCenter = NotificationCenter()
    ) -> (GuessWhoSync, PlaceCorpusCountingStore) {
        let store = PlaceCorpusCountingStore()
        let sync = GuessWhoSync(
            contacts: InMemoryContactStore(),
            events: InMemoryEventStore(),
            sidecars: store,
            deviceID: "device-A",
            notificationCenter: notificationCenter
        )
        return (sync, store)
    }

    // MARK: - Create + read round-trip

    @Test func createGuideRoundTripsGuideAndPlaces() throws {
        let (sync, _) = makeOrchestrator()
        let guideID = try sync.createGuide(
            from: sampleSnapshot,
            sourceURL: "https://maps.apple/ug/abc"
        )

        let guides = try sync.allGuides()
        #expect(guides.count == 1)
        let guide = try #require(guides.first)
        #expect(guide.id == guideID)
        #expect(guide.name == "Berlin")
        #expect(guide.sourceURL == "https://maps.apple/ug/abc")
        #expect(guide.createdAt != nil)

        let places = try sync.places(inGuide: guideID)
        #expect(places.count == 3)
        // Entry order is preserved through the orderCache cell.
        #expect(places[0].mapsPlaceID == "ID09B4D36386DC9DA")
        #expect(places[0].needsResolution)
        #expect(places[0].name.isEmpty)
        #expect(places[1].mapsPlaceID == nil)
        #expect(places[1].address?.hasPrefix("Samariterstraße") == true)
        #expect(places[1].latitude != nil && abs(places[1].latitude! - 52.5169198) < 0.000001)
        #expect(!places[1].needsResolution)
        #expect(places[2].mapsPlaceID == "I2C0916C36239E325")
        #expect(places.allSatisfy { $0.guideID == guideID })
    }

    @Test func guideLookupByKeyAndMissingGuide() throws {
        let (sync, _) = makeOrchestrator()
        let guideID = try sync.createGuide(from: sampleSnapshot, sourceURL: nil)

        let found = try sync.guide(at: SidecarKey(kind: .guide, id: guideID.uuidString))
        #expect(found?.name == "Berlin")
        #expect(found?.sourceURL == nil)

        let missing = try sync.guide(at: SidecarKey(kind: .guide, id: UUID().uuidString))
        #expect(missing == nil)
    }

    @Test func placesAreScopedToTheirGuide() throws {
        let (sync, _) = makeOrchestrator()
        let first = try sync.createGuide(from: sampleSnapshot, sourceURL: nil)
        let second = try sync.createGuide(
            from: MapsGuideURL.Snapshot(
                name: "Tokyo",
                entries: [MapsGuideURL.Entry(mapsPlaceID: "IABC123")]
            ),
            sourceURL: nil
        )

        #expect(try sync.places(inGuide: first).count == 3)
        #expect(try sync.places(inGuide: second).count == 1)
        #expect(try sync.allPlaces().count == 4)
    }

    // MARK: - Place corpus cache

    @Test func concurrentAllPlacesCallsShareOneCorpusWalk() throws {
        let (sync, store) = makeCountingOrchestrator()
        _ = try sync.createGuide(from: sampleSnapshot, sourceURL: nil)
        store.resetCounts(blockNextWalk: true)

        let firstResult = LockedResult<[MapsPlace]>()
        let firstFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            firstResult.store(Result { try sync.allPlaces() })
            firstFinished.signal()
        }

        #expect(store.waitUntilWalkIsBlocked() == .success)
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + .milliseconds(100)) {
            store.resumeBlockedWalk()
        }

        let second = try sync.allPlaces()
        #expect(firstFinished.wait(timeout: .now() + .seconds(2)) == .success)
        let stored = try #require(firstResult.load())
        let first = try stored.get()

        #expect(first.count == 3)
        #expect(second.count == 3)
        #expect(store.allKeysCallCount == 1)
        #expect(store.placeReadCount == 3)
    }

    @Test func cachedAllPlacesDoesNotRewalkUnchangedCorpus() throws {
        let (sync, store) = makeCountingOrchestrator()
        _ = try sync.createGuide(from: sampleSnapshot, sourceURL: nil)
        store.resetCounts()

        #expect(try sync.allPlaces().count == 3)
        #expect(try sync.allPlaces().count == 3)

        #expect(store.allKeysCallCount == 1)
        #expect(store.placeReadCount == 3)
    }

    @Test func localPlaceCreateUpdateAndDeleteInvalidateCachedCorpus() throws {
        let (sync, store) = makeCountingOrchestrator()
        #expect(try sync.allPlaces().isEmpty)

        store.resetCounts()
        let guideID = try sync.createGuide(
            from: MapsGuideURL.Snapshot(
                name: "Berlin",
                entries: [MapsGuideURL.Entry(mapsPlaceID: "IABC123")]
            ),
            sourceURL: nil
        )
        let created = try #require(try sync.allPlaces().first)
        #expect(created.guideID == guideID)
        #expect(store.allKeysCallCount == 1)

        store.resetCounts()
        let key = SidecarKey(kind: .place, id: created.id.uuidString)
        try sync.markPlaceResolved(
            at: key,
            name: "Updated Place",
            address: "123 Test Street, Berlin",
            latitude: 52.5,
            longitude: 13.4
        )
        let updated = try #require(try sync.allPlaces().first)
        #expect(updated.name == "Updated Place")
        #expect(store.allKeysCallCount == 1)

        store.resetCounts()
        try sync.deletePlace(at: key)
        #expect(try sync.allPlaces().isEmpty)
        #expect(store.allKeysCallCount == 1)
    }

    @Test func localGuideWriteInvalidatesCachedCorpusGeneration() throws {
        let (sync, store) = makeCountingOrchestrator()
        let guideID = try sync.createGuide(from: sampleSnapshot, sourceURL: nil)
        #expect(try sync.allPlaces().count == 3)
        store.resetCounts()

        try sync.stampGuideViewed(
            at: SidecarKey(kind: .guide, id: guideID.uuidString),
            now: Date(timeIntervalSinceReferenceDate: 123)
        )

        #expect(try sync.allPlaces().count == 3)
        #expect(store.allKeysCallCount == 1)
        #expect(store.placeReadCount == 3)
    }

    @Test func remoteSidecarNotificationInvalidatesCachedCorpus() throws {
        let notificationCenter = NotificationCenter()
        let (sync, store) = makeCountingOrchestrator(notificationCenter: notificationCenter)
        let remoteSync = GuessWhoSync(
            contacts: InMemoryContactStore(),
            events: InMemoryEventStore(),
            sidecars: store,
            deviceID: "remote-device",
            notificationCenter: NotificationCenter()
        )
        let guideID = try sync.createGuide(
            from: MapsGuideURL.Snapshot(
                name: "Berlin",
                entries: [MapsGuideURL.Entry(mapsPlaceID: "IABC123")]
            ),
            sourceURL: nil
        )
        let original = try #require(try sync.places(inGuide: guideID).first)

        try remoteSync.markPlaceResolved(
            at: SidecarKey(kind: .place, id: original.id.uuidString),
            name: "Remote Name",
            address: nil,
            latitude: nil,
            longitude: nil
        )
        store.resetCounts()

        // The primary engine still owns its pre-notification generation.
        #expect(try sync.allPlaces().first?.name == original.name)
        #expect(store.allKeysCallCount == 0)

        notificationCenter.post(name: .guessWhoSidecarsDidChange, object: nil)

        #expect(try sync.allPlaces().first?.name == "Remote Name")
        #expect(store.allKeysCallCount == 1)
        #expect(store.placeReadCount == 1)
    }

    // MARK: - Refresh

    @Test func importGuideExactSourceURLRefreshesInsteadOfDuplicating() throws {
        let (sync, _) = makeOrchestrator()
        let sourceURL = "https://maps.apple/ug/abc"
        let originalID = try sync.importGuide(
            from: sampleSnapshot,
            sourceURL: sourceURL
        )
        let original = try #require(
            try sync.guide(at: SidecarKey(kind: .guide, id: originalID.uuidString))
        )

        let refreshedSnapshot = MapsGuideURL.Snapshot(
            name: "Berlin Updated",
            entries: [MapsGuideURL.Entry(mapsPlaceID: "ID09B4D36386DC9DA")]
        )
        let importedID = try sync.importGuide(
            from: refreshedSnapshot,
            sourceURL: sourceURL
        )

        #expect(importedID == originalID)
        let guides = try sync.allGuides()
        #expect(guides.count == 1)
        #expect(guides.first?.name == "Berlin Updated")
        #expect(guides.first?.createdAt == original.createdAt)
        #expect(try sync.places(inGuide: originalID).count == 1)
    }

    @Test func importGuideSourceURLMatchIsExact() throws {
        let (sync, _) = makeOrchestrator()
        let firstID = try sync.importGuide(
            from: sampleSnapshot,
            sourceURL: "https://maps.apple/ug/abc"
        )
        let secondID = try sync.importGuide(
            from: sampleSnapshot,
            sourceURL: "https://maps.apple/ug/abc/"
        )

        #expect(secondID != firstID)
        #expect(try sync.allGuides().count == 2)
    }

    // MARK: - Name-collision lookup (backs "Import as New" / "Update Guide")

    @Test func guidesMatchingNameIsCaseAndWhitespaceInsensitive() throws {
        let (sync, _) = makeOrchestrator()
        let berlinID = try sync.createGuide(from: sampleSnapshot, sourceURL: "https://maps.apple/ug/a")
        _ = try sync.createGuide(
            from: MapsGuideURL.Snapshot(name: "Tokyo", entries: []),
            sourceURL: "https://maps.apple/ug/b"
        )

        // Exact, differently-cased, and whitespace-padded names all match.
        for needle in ["Berlin", "berlin", "  BERLIN  "] {
            let matches = try sync.guides(matchingName: needle)
            #expect(matches.count == 1)
            #expect(matches.first?.id == berlinID)
        }

        // A different name, and an empty/blank needle, match nothing.
        #expect(try sync.guides(matchingName: "Munich").isEmpty)
        #expect(try sync.guides(matchingName: "").isEmpty)
        #expect(try sync.guides(matchingName: "   ").isEmpty)
    }

    @Test func guidesMatchingNameReturnsAllMatchesOldestFirst() throws {
        let (sync, _) = makeOrchestrator()
        let first = try sync.createGuide(from: sampleSnapshot, sourceURL: "https://maps.apple/ug/1")
        let second = try sync.createGuide(from: sampleSnapshot, sourceURL: "https://maps.apple/ug/2")

        let matches = try sync.guides(matchingName: "Berlin")
        #expect(matches.count == 2)
        // Oldest-created first (createdAt, UUID tiebreak) — the UI updates the
        // first match on "Update Guide".
        #expect(Set(matches.map(\.id)) == Set([first, second]))
    }

    @Test func guidesMatchingNameExcludesDeletedGuides() throws {
        let (sync, _) = makeOrchestrator()
        let doomed = try sync.createGuide(from: sampleSnapshot, sourceURL: "https://maps.apple/ug/x")
        try sync.deleteGuide(at: SidecarKey(kind: .guide, id: doomed.uuidString))

        #expect(try sync.guides(matchingName: "Berlin").isEmpty)
    }

    @Test func refreshGuideReconcilesSnapshotInPlace() throws {
        let (sync, _) = makeOrchestrator()
        let sourceURL = "https://maps.apple/ug/abc"
        let guideID = try sync.createGuide(from: sampleSnapshot, sourceURL: sourceURL)
        let originalGuide = try #require(
            try sync.guide(at: SidecarKey(kind: .guide, id: guideID.uuidString))
        )
        let originalPlaces = try sync.places(inGuide: guideID)
        let retainedAddress = originalPlaces[1]
        let retainedPlaceID = originalPlaces[0]
        let removedPlaceID = originalPlaces[2]

        // Resolution data belongs to the retained local place and must survive
        // a guide refresh whose payload still contains the same Maps place ID.
        try sync.markPlaceResolved(
            at: SidecarKey(kind: .place, id: retainedPlaceID.id.uuidString),
            name: "nhow",
            address: "Stralauer Allee 3, Berlin",
            latitude: 52.5012787,
            longitude: 13.4507933
        )
        let viewedAt = Date(timeIntervalSinceReferenceDate: 12_345)
        try sync.stampGuideViewed(
            at: SidecarKey(kind: .guide, id: guideID.uuidString),
            now: viewedAt
        )

        // The user has dragged the address ahead of the resolved place. The
        // refreshed Apple snapshot below puts those retained entries in the
        // opposite order; refresh must preserve this local choice.
        try sync.reorderPlaces(
            inGuide: guideID,
            orderedIDs: [retainedAddress.id, retainedPlaceID.id, removedPlaceID.id]
        )

        let refreshed = MapsGuideURL.Snapshot(
            name: "Berlin Favorites",
            entries: [
                MapsGuideURL.Entry(mapsPlaceID: "ID09B4D36386DC9DA"),
                MapsGuideURL.Entry(mapsPlaceID: "INEWPLACE"),
                MapsGuideURL.Entry(
                    address: "Samariterstraße 31, Friedrichshain, 10247 Berlin, Germany",
                    latitude: 52.517,
                    longitude: 13.4652
                ),
            ]
        )

        let didRefresh = try sync.refreshGuide(
            at: SidecarKey(kind: .guide, id: guideID.uuidString),
            from: refreshed,
            sourceURL: sourceURL
        )
        #expect(didRefresh)

        let guide = try #require(
            try sync.guide(at: SidecarKey(kind: .guide, id: guideID.uuidString))
        )
        #expect(guide.id == guideID)
        #expect(guide.name == "Berlin Favorites")
        #expect(guide.sourceURL == sourceURL)
        #expect(guide.createdAt == originalGuide.createdAt)
        #expect(guide.lastViewedAt != nil)
        #expect(abs(guide.lastViewedAt!.timeIntervalSinceReferenceDate - viewedAt.timeIntervalSinceReferenceDate) < 1)

        let places = try sync.places(inGuide: guideID)
        #expect(places.count == 3)
        #expect(places.map(\.sortOrder) == [0, 1, 2])
        #expect(places[0].id == retainedAddress.id)
        #expect(places[0].latitude == 52.517)
        #expect(places[1].id == retainedPlaceID.id)
        #expect(places[1].name == "nhow")
        #expect(!places[1].needsResolution)
        #expect(places[2].mapsPlaceID == "INEWPLACE")
        #expect(places[2].needsResolution)
        #expect(!places.contains { $0.id == removedPlaceID.id })
    }

    @Test func refreshGuideDoesNotMintAMissingGuide() throws {
        let (sync, _) = makeOrchestrator()
        let didRefresh = try sync.refreshGuide(
            at: SidecarKey(kind: .guide, id: UUID().uuidString),
            from: sampleSnapshot,
            sourceURL: "https://maps.apple/ug/abc"
        )

        #expect(!didRefresh)
        #expect(try sync.allGuides().isEmpty)
        #expect(try sync.allPlaces().isEmpty)
    }

    // MARK: - Resolution

    @Test func markPlaceResolvedFillsFieldsAndStopsNeedingResolution() throws {
        let (sync, _) = makeOrchestrator()
        let guideID = try sync.createGuide(from: sampleSnapshot, sourceURL: nil)
        let unresolved = try #require(
            try sync.places(inGuide: guideID).first { $0.needsResolution }
        )

        try sync.markPlaceResolved(
            at: SidecarKey(kind: .place, id: unresolved.id.uuidString),
            name: "nhow",
            address: "Stralauer Allee 3, Friedrichshain, 10245 Berlin",
            latitude: 52.5012787,
            longitude: 13.4507933
        )

        let places = try sync.places(inGuide: guideID)
        let resolved = try #require(places.first { $0.id == unresolved.id })
        #expect(resolved.name == "nhow")
        #expect(resolved.address?.hasPrefix("Stralauer") == true)
        #expect(resolved.latitude != nil && abs(resolved.latitude! - 52.5012787) < 0.000001)
        #expect(resolved.resolvedAt != nil)
        #expect(!resolved.needsResolution)
        // The place ID is retained after resolution (it stays the durable
        // pointer back into Apple Maps).
        #expect(resolved.mapsPlaceID == unresolved.mapsPlaceID)
    }

    @Test func markPlaceResolvedIsANoOpForMissingSidecar() throws {
        let (sync, _) = makeOrchestrator()
        // Must not throw or mint an envelope.
        try sync.markPlaceResolved(
            at: SidecarKey(kind: .place, id: UUID().uuidString),
            name: "ghost",
            address: nil,
            latitude: nil,
            longitude: nil
        )
        #expect(try sync.allPlaces().isEmpty)
    }

    // MARK: - Last viewed

    @Test func stampGuideViewedRoundTrips() throws {
        let (sync, _) = makeOrchestrator()
        let guideID = try sync.createGuide(from: sampleSnapshot, sourceURL: nil)
        let key = SidecarKey(kind: .guide, id: guideID.uuidString)

        // Never-viewed guides carry no stamp.
        #expect(try sync.guide(at: key)?.lastViewedAt == nil)

        let now = Date(timeIntervalSinceReferenceDate: 12_345)
        try sync.stampGuideViewed(at: key, now: now)

        let stamped = try #require(try sync.guide(at: key))
        let readBack = try #require(stamped.lastViewedAt)
        #expect(abs(readBack.timeIntervalSinceReferenceDate - now.timeIntervalSinceReferenceDate) < 1)
        // Additive: name and source cells survive the stamp.
        #expect(stamped.name == "Berlin")
    }

    @Test func stampGuideViewedIsANoOpForMissingSidecar() throws {
        let (sync, _) = makeOrchestrator()
        // Must not throw or mint an envelope.
        try sync.stampGuideViewed(at: SidecarKey(kind: .guide, id: UUID().uuidString))
        #expect(try sync.allGuides().isEmpty)
    }

    @Test func stampPlaceViewedRoundTrips() throws {
        let (sync, _) = makeOrchestrator()
        let guideID = try sync.createGuide(from: sampleSnapshot, sourceURL: nil)
        let place = try #require(try sync.places(inGuide: guideID).first)
        let key = SidecarKey(kind: .place, id: place.id.uuidString)

        // Never-viewed places carry no stamp.
        #expect(place.lastViewedAt == nil)

        let now = Date(timeIntervalSinceReferenceDate: 67_890)
        try sync.stampPlaceViewed(at: key, now: now)

        let stamped = try #require(try sync.places(inGuide: guideID).first { $0.id == place.id })
        let readBack = try #require(stamped.lastViewedAt)
        #expect(abs(readBack.timeIntervalSinceReferenceDate - now.timeIntervalSinceReferenceDate) < 1)
        // Additive: the place's guide membership and order survive the stamp.
        #expect(stamped.guideID == guideID)
        #expect(stamped.sortOrder == place.sortOrder)
    }

    @Test func stampPlaceViewedIsANoOpForMissingSidecar() throws {
        let (sync, _) = makeOrchestrator()
        // Must not throw or mint an envelope.
        try sync.stampPlaceViewed(at: SidecarKey(kind: .place, id: UUID().uuidString))
        #expect(try sync.allPlaces().isEmpty)
    }

    // MARK: - Reorder

    @Test func reorderPlacesRewritesEntryOrder() throws {
        let (sync, _) = makeOrchestrator()
        let guideID = try sync.createGuide(from: sampleSnapshot, sourceURL: nil)
        let original = try sync.places(inGuide: guideID)
        #expect(original.map(\.sortOrder) == [0, 1, 2])

        // Move the last place to the front.
        let reordered = [original[2].id, original[0].id, original[1].id]
        try sync.reorderPlaces(inGuide: guideID, orderedIDs: reordered)

        let after = try sync.places(inGuide: guideID)
        #expect(after.map(\.id) == reordered)
        #expect(after.map(\.sortOrder) == [0, 1, 2])
    }

    @Test func reorderPlacesSkipsUnknownIDsAndMissingSidecars() throws {
        let (sync, _) = makeOrchestrator()
        let guideID = try sync.createGuide(from: sampleSnapshot, sourceURL: nil)
        let original = try sync.places(inGuide: guideID)

        // An unknown id interleaved with real ones is ignored; the real places
        // still land at their listed positions.
        let ghost = UUID()
        try sync.reorderPlaces(
            inGuide: guideID,
            orderedIDs: [original[1].id, ghost, original[2].id, original[0].id]
        )

        let after = try sync.places(inGuide: guideID)
        #expect(after.map(\.id) == [original[1].id, original[2].id, original[0].id])
    }

    // MARK: - Deletion

    @Test func deleteGuideHidesGuideAndItsPlaces() throws {
        let (sync, _) = makeOrchestrator()
        let keep = try sync.createGuide(
            from: MapsGuideURL.Snapshot(name: "Tokyo", entries: [MapsGuideURL.Entry(mapsPlaceID: "IABC")]),
            sourceURL: nil
        )
        let doomed = try sync.createGuide(from: sampleSnapshot, sourceURL: nil)

        try sync.deleteGuide(at: SidecarKey(kind: .guide, id: doomed.uuidString))

        let guides = try sync.allGuides()
        #expect(guides.map(\.id) == [keep])
        #expect(try sync.places(inGuide: doomed).isEmpty)
        #expect(try sync.places(inGuide: keep).count == 1)
    }

    @Test func deletePlaceHidesOnlyThatPlace() throws {
        let (sync, _) = makeOrchestrator()
        let guideID = try sync.createGuide(from: sampleSnapshot, sourceURL: nil)
        let places = try sync.places(inGuide: guideID)
        let victim = try #require(places.first)

        try sync.deletePlace(at: SidecarKey(kind: .place, id: victim.id.uuidString))

        let remaining = try sync.places(inGuide: guideID)
        #expect(remaining.count == 2)
        #expect(!remaining.contains { $0.id == victim.id })
    }

    // MARK: - Key canonicalization

    @Test func guideAndPlaceKeysLowercaseLikeOtherKinds() {
        let id = "ABCDEF00-1111-2222-3333-444455556666"
        #expect(SidecarKey(kind: .guide, id: id).id == id.lowercased())
        #expect(SidecarKey(kind: .place, id: id).id == id.lowercased())
    }
}

private final class PlaceCorpusCountingStore: SidecarStoreProtocol, @unchecked Sendable {
    private let inner = InMemorySidecarStore()
    private let lock = NSLock()
    private let walkStarted = DispatchSemaphore(value: 0)
    private let walkMayContinue = DispatchSemaphore(value: 0)
    private var shouldBlockNextWalk = false
    private var storedAllKeysCallCount = 0
    private var storedPlaceReadCount = 0

    var allKeysCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedAllKeysCallCount
    }

    var placeReadCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedPlaceReadCount
    }

    func resetCounts(blockNextWalk: Bool = false) {
        lock.lock()
        storedAllKeysCallCount = 0
        storedPlaceReadCount = 0
        shouldBlockNextWalk = blockNextWalk
        lock.unlock()
    }

    func waitUntilWalkIsBlocked() -> DispatchTimeoutResult {
        walkStarted.wait(timeout: .now() + .seconds(2))
    }

    func resumeBlockedWalk() {
        walkMayContinue.signal()
    }

    func read(_ key: SidecarKey) throws -> SidecarEnvelope? {
        if key.kind == .place {
            lock.lock()
            storedPlaceReadCount += 1
            lock.unlock()
        }
        return try inner.read(key)
    }

    func write(_ envelope: SidecarEnvelope, at key: SidecarKey) throws {
        try inner.write(envelope, at: key)
    }

    func delete(_ key: SidecarKey) throws {
        try inner.delete(key)
    }

    func allKeys() throws -> [SidecarKey] {
        lock.lock()
        storedAllKeysCallCount += 1
        let shouldBlock = shouldBlockNextWalk
        shouldBlockNextWalk = false
        lock.unlock()

        if shouldBlock {
            walkStarted.signal()
            walkMayContinue.wait()
        }
        return try inner.allKeys()
    }

    func downloadStatus(_ key: SidecarKey) -> SidecarDownloadStatus {
        inner.downloadStatus(key)
    }

    func requestDownload(_ key: SidecarKey) throws {
        try inner.requestDownload(key)
    }
}

private final class LockedResult<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Value, Error>?

    func store(_ result: Result<Value, Error>) {
        lock.lock()
        self.result = result
        lock.unlock()
    }

    func load() -> Result<Value, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return result
    }
}
