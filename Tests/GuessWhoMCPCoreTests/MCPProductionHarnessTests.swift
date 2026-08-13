import XCTest
import GuessWhoSync
import GuessWhoSyncTesting
import GuessWhoMCPCore
import GuessWhoMCPWire

/// Smoke tests for the production-backed MCP harness (`MCPProductionFixture`).
///
/// They prove the harness builds and RUNS end-to-end: a representative
/// dispatcher request reads through the REAL `ContactsRepository`, the favorite
/// surface reads the REAL on-disk `FavoritesStore`, and the substituted OS
/// boundary (`RecordingContactStore`) injects its two one-shot faults at the
/// exact points a parity test needs — a save at a chosen ordinal, and a photo
/// write AFTER the repository has snapshotted the prior image. The deep
/// per-tool parity assertions live in the feature suites; this file only
/// guards the harness itself.
@MainActor
final class MCPProductionHarnessTests: XCTestCase {

    // MARK: - Reads flow through the production stack

    /// A `contacts_list` dispatch returns the seeded book read through the real
    /// repository cache — the reconciled person lists under her GuessWho UUID.
    func testContactsListReadsThroughRepository() async {
        let fixture = await MCPProductionFixture.make()
        defer { fixture.cleanUp() }

        let response = await fixture.dispatcher.handle(.contactsList(
            helperId: MCPProductionFixture.helper, messageId: TestMessageID.next(),
            kind: nil, favoritesOnly: nil, groupId: nil, limit: nil, cursor: nil))

        guard case .contactPage(_, _, let page) = response else {
            return XCTFail("expected a contact page; got \(String(describing: response))")
        }
        XCTAssertEqual(
            page.items.map(\.name).sorted(),
            ["Ada Lovelace", "Analytical Engines", "Blaise Pascal"],
            "the dispatcher enumerates the repository's seeded book")
        XCTAssertEqual(
            page.items.first(where: { $0.name == "Ada Lovelace" })?.id,
            MCPProductionFixture.adaGuessWhoID,
            "a reconciled contact lists under its GuessWho UUID")
    }

    /// A `contacts_list` filtered by the seeded group returns exactly its
    /// member — proving the group + membership seed reached the real store and
    /// the repository resolves the membership.
    func testContactsListGroupFilterReadsSeededMembership() async {
        let fixture = await MCPProductionFixture.make()
        defer { fixture.cleanUp() }

        // Obtain the group's WIRE id the way an agent would — from
        // contacts_list_groups (which reads the real repository group cache).
        let groupsResponse = await fixture.dispatcher.handle(.contactsListGroups(
            helperId: MCPProductionFixture.helper, messageId: TestMessageID.next(),
            limit: nil, cursor: nil))
        guard case .groupPage(_, _, let groups) = groupsResponse,
              let groupID = groups.items.first(where: {
                  $0.name == MCPProductionFixture.groupName
              })?.id
        else {
            return XCTFail("expected the seeded group in a group page; got \(String(describing: groupsResponse))")
        }

        let response = await fixture.dispatcher.handle(.contactsList(
            helperId: MCPProductionFixture.helper, messageId: TestMessageID.next(),
            kind: nil, favoritesOnly: nil, groupId: groupID, limit: nil, cursor: nil))

        guard case .contactPage(_, _, let page) = response else {
            return XCTFail("expected a contact page; got \(String(describing: response))")
        }
        XCTAssertEqual(page.items.map(\.name), ["Ada Lovelace"],
                       "only the seeded group member is listed")
    }

    /// A `favorites_list` dispatch reads the REAL on-disk `Favorites.json`
    /// through the thin `MCPFavoriteStoreAdapter`, resolving the favorite's
    /// referent against the repository.
    func testFavoritesListReadsRealOnDiskFavorite() async throws {
        let fixture = await MCPProductionFixture.make()
        defer { fixture.cleanUp() }

        // The favorite really is on disk.
        let onDisk = try fixture.storedFavorites()
        XCTAssertEqual(onDisk.map(\.id), [MCPProductionFixture.adaGuessWhoID])

        let response = await fixture.dispatcher.handle(.favoritesList(
            helperId: MCPProductionFixture.helper, messageId: TestMessageID.next(),
            limit: nil, cursor: nil))

        guard case .favoritePage(_, _, let page) = response else {
            return XCTFail("expected a favorite page; got \(String(describing: response))")
        }
        XCTAssertEqual(page.items.map(\.id), [MCPProductionFixture.adaGuessWhoID])
        XCTAssertEqual(page.items.first?.displayName, "Ada Lovelace",
                       "the referent resolves through the real repository")
        XCTAssertTrue(page.items.first?.isAvailable ?? false)
    }

    // MARK: - The favorite adapter delegates, never re-implements

    /// The adapter's `setFavorite` is idempotent because `FavoritesStore.set`
    /// is — a re-add reports "no change" and the on-disk list is unchanged. The
    /// adapter contributes no logic of its own.
    func testFavoriteAdapterDelegatesIdempotentSet() async throws {
        let fixture = await MCPProductionFixture.make()
        defer { fixture.cleanUp() }

        // Ada is already favorited by the seed; a repeat add is a no-op write.
        let changedAgain = try fixture.favoriteSource.setFavorite(
            kind: .contact, id: MCPProductionFixture.adaGuessWhoID, favorite: true)
        XCTAssertFalse(changedAgain, "an already-satisfied set reports no change")

        // A brand-new referent is a real change.
        let addedNew = try fixture.favoriteSource.setFavorite(
            kind: .guide, id: UUID().uuidString, favorite: true)
        XCTAssertTrue(addedNew)

        // Both outcomes are reflected on disk, written by the real store.
        XCTAssertEqual(try fixture.storedFavorites().count, 2)
    }

    // MARK: - The recording store's one-shot faults

    /// Arming a save failure at ordinal 1 makes the first `saveContact` throw,
    /// commit nothing, and leave the store record unchanged — while the boundary
    /// still counts the attempt.
    func testOneShotSaveFaultAtOrdinal() async throws {
        let fixture = await MCPProductionFixture.make()
        defer { fixture.cleanUp() }

        let adaID = try XCTUnwrap(fixture.contact(localID: MCPProductionFixture.adaLocalID)).contactID
        let editable = try await fixture.repository.editableContact(id: adaID)
        var edited = try XCTUnwrap(editable)
        edited.jobTitle = "Countess"

        await fixture.store.failSave(atOrdinal: 1, with: HarnessInjectedFailure(site: .save))

        do {
            try await fixture.repository.saveContact(edited, for: adaID)
            XCTFail("the injected fault should have made the save throw")
        } catch let error as HarnessInjectedFailure {
            XCTAssertEqual(error.site, .save)
        }

        // The attempt counted, but nothing committed.
        let saveCount = await fixture.store.saveCount
        let committed = await fixture.store.committedSaveLocalIDs
        XCTAssertEqual(saveCount, 1)
        XCTAssertTrue(committed.isEmpty)

        // The record on disk still holds the original job title.
        let fetched = try await fixture.store.fetch(localID: MCPProductionFixture.adaLocalID)
        let stored = try XCTUnwrap(fetched)
        XCTAssertEqual(stored.jobTitle, "Analyst")
    }

    /// The one-shot photo fault fires INSIDE the boundary's `setImageData`,
    /// i.e. AFTER `setContactPhoto` has already read the prior bytes and written
    /// the `previousPhoto` snapshot: the snapshot is durable on disk, the live
    /// photo bytes are unchanged, and the boundary recorded the attempt without
    /// committing it.
    func testPhotoFaultFiresAfterPriorImageSnapshot() async throws {
        let fixture = await MCPProductionFixture.make()
        defer { fixture.cleanUp() }

        let oldBytes = Data([0xFF, 0xD8, 0xFF, 0x01, 0x02]) // JPEG-ish header
        await fixture.seedPhoto(oldBytes, forLocalID: MCPProductionFixture.adaLocalID)

        let adaID = try XCTUnwrap(fixture.contact(localID: MCPProductionFixture.adaLocalID)).contactID
        await fixture.store.failNextPhotoWrite(with: HarnessInjectedFailure(site: .photo))

        let newBytes = Data([0x10, 0x20, 0x30])
        do {
            _ = try await fixture.repository.setContactPhoto(for: adaID, imageData: newBytes)
            XCTFail("the injected fault should have made the photo write throw")
        } catch let error as HarnessInjectedFailure {
            XCTAssertEqual(error.site, .photo)
        }

        // The prior image was snapshotted to disk BEFORE the fault.
        let snapshot = try fixture.storedPreviousPhoto(forGuessWhoID: MCPProductionFixture.adaGuessWhoID)
        XCTAssertEqual(snapshot, oldBytes, "the previousPhoto snapshot is durable")

        // The live photo bytes never changed — the write was rejected.
        let live = try await fixture.storedPhoto(forLocalID: MCPProductionFixture.adaLocalID)
        XCTAssertEqual(live, oldBytes, "the failed write left the live photo intact")

        // The boundary recorded the attempt but committed nothing.
        let attempts = await fixture.store.photoWriteAttempts
        let committed = await fixture.store.committedPhotoWrites
        XCTAssertEqual(attempts, [RecordingContactStore.PhotoWrite(
            localID: MCPProductionFixture.adaLocalID, cleared: false)])
        XCTAssertTrue(committed.isEmpty)
    }
}
