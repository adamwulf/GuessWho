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

    // MARK: - Refresh

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

        let refreshed = MapsGuideURL.Snapshot(
            name: "Berlin Favorites",
            entries: [
                MapsGuideURL.Entry(
                    address: "Samariterstraße 31, Friedrichshain, 10247 Berlin, Germany",
                    latitude: 52.517,
                    longitude: 13.4652
                ),
                MapsGuideURL.Entry(mapsPlaceID: "INEWPLACE"),
                MapsGuideURL.Entry(mapsPlaceID: "ID09B4D36386DC9DA"),
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
        #expect(places[1].mapsPlaceID == "INEWPLACE")
        #expect(places[1].needsResolution)
        #expect(places[2].id == retainedPlaceID.id)
        #expect(places[2].name == "nhow")
        #expect(!places[2].needsResolution)
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
