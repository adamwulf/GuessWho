import XCTest
import GuessWhoSync
import GuessWhoMCPCore
import GuessWhoMCPWire

/// The generic connection tools (links_list / links_create / links_delete)
/// against REAL link storage: every test here sets
/// `contacts.linkEngine = fixture.linkEngine`, so link envelopes are
/// written by the production `GuessWhoSync.addLink` into a real
/// temp-directory `FileSystemSidecarStore` and read back by the production
/// `links(at:)` scan — the symmetric-endpoint, tombstone, and id→key
/// mapping assertions exercise the shipping storage path, not a fake.
/// The only fakes left are the contact/event/place record BOOKS (the real
/// ones need the system Contacts/EventKit stores + TCC, which headless
/// `swift test` can't have).
final class LinkToolTests: XCTestCase {

    private func expectError(
        _ response: WireResponse?, code: WireErrorCode, message: String? = nil,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        guard let payload = response?.errorPayload else {
            return XCTFail(
                "expected \(code) error, got \(String(describing: response))",
                file: file, line: line)
        }
        XCTAssertEqual(payload.code, code, file: file, line: line)
        if let message {
            XCTAssertEqual(payload.message, message, file: file, line: line)
        }
    }

    /// A writable fixture whose ENTIRE link surface rides the real engine.
    private func linkFixture() async -> Fixture {
        let fixture = await Fixture.make()
        await MainActor.run {
            fixture.gates.mcpAccess = .readWrite
            fixture.gates.cliAccess = .readWrite
            fixture.contacts.linkEngine = fixture.linkEngine
        }
        return fixture
    }

    private func contactID(_ fixture: Fixture, query: String, name: String) async -> String? {
        let response = await fixture.dispatcher.handle(.contactsSearch(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            query: query, limit: nil, cursor: nil))
        guard case .contactPage(_, _, let page) = response else { return nil }
        return page.items.first(where: { $0.name == name })?.id
    }

    private func eventID(_ fixture: Fixture, title: String) async -> String? {
        let response = await fixture.dispatcher.handle(.eventsList(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            startDate: "2025-01-01T00:00:00Z", endDate: "2025-12-01T00:00:00Z",
            limit: nil, cursor: nil))
        guard case .eventPage(_, _, let page) = response else { return nil }
        return page.items.first(where: { $0.title == title })?.id
    }

    private func placeID(_ fixture: Fixture) async -> String? {
        let response = await fixture.dispatcher.handle(.placesList(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            guideId: nil, limit: nil, cursor: nil))
        guard case .placePage(_, _, let page) = response else { return nil }
        return page.items.first?.id
    }

    private func create(
        _ fixture: Fixture, fromId: String, fromKind: String, toId: String, toKind: String,
        note: String? = nil, token: String? = nil
    ) async -> WireResponse? {
        await fixture.dispatcher.handle(.linksCreate(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            fromId: fromId, fromKind: fromKind, toId: toId, toKind: toKind,
            note: note, idempotencyToken: token))
    }

    private func list(_ fixture: Fixture, id: String, kind: String) async -> [WireLink]? {
        let response = await fixture.dispatcher.handle(.linksList(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            id: id, kind: kind, limit: nil, cursor: nil))
        guard case .linkPage(_, _, let page) = response else { return nil }
        return page.items
    }

    /// No live link touches any endpoint in the REAL store — the
    /// nothing-was-written assertion for rejection tests.
    private func assertStoreHasNoLiveLinks(
        _ fixture: Fixture, file: StaticString = #filePath, line: UInt = #line
    ) {
        for kind in [SidecarKind.contact, .event, .place, .guide] {
            let endpoints = (try? fixture.linkEngine.linkedEndpoints(ofKind: kind)) ?? []
            XCTAssertTrue(
                endpoints.isEmpty,
                "expected no live links at \(kind) endpoints", file: file, line: line)
        }
    }

    // MARK: - Every app-supported pair, symmetric via the real store

    func testContactContactLinkRoundTripsSymmetrically() async {
        let fixture = await linkFixture()
        guard let jane = await contactID(fixture, query: "jane", name: "Jane Doe"),
              let fresh = await contactID(fixture, query: "fresh", name: "Fresh Face")
        else { return XCTFail("missing fixture contacts") }

        let created = await create(
            fixture, fromId: jane, fromKind: "person", toId: fresh, toKind: "person",
            note: "College roommate")
        guard case .link(_, _, let echo) = created else {
            return XCTFail("expected link echo, got \(String(describing: created))")
        }
        XCTAssertEqual(echo.kind, "person")
        XCTAssertEqual(echo.otherId, fresh, "the far id is the id the agent already holds")
        XCTAssertEqual(echo.note, "College roommate")

        // Visible from BOTH endpoints — one Link object, found by the real
        // engine scan from either side. Fresh Face minted during the write;
        // its pre-mint wire id keeps resolving (deterministic mint).
        guard let fromJane = await list(fixture, id: jane, kind: "person"),
              let fromFresh = await list(fixture, id: fresh, kind: "person")
        else { return XCTFail("links_list failed") }
        XCTAssertEqual(fromJane.map(\.id), [echo.id])
        XCTAssertEqual(fromJane.first?.otherId, fresh)
        XCTAssertEqual(fromFresh.map(\.id), [echo.id])
        XCTAssertEqual(fromFresh.first?.otherId, jane)
        XCTAssertEqual(fromFresh.first?.kind, "person")
    }

    func testContactOrganizationLinkEnforcesDeclaredKinds() async {
        let fixture = await linkFixture()
        guard let jane = await contactID(fixture, query: "jane", name: "Jane Doe"),
              let organization = await contactID(fixture, query: "doe", name: "Doe Industries")
        else { return XCTFail("missing fixture contacts") }

        // Declared kind must match the record: the org id as "person" (and
        // vice versa) is the linked-contact tools' rule, kept here.
        let mismatch = await create(
            fixture, fromId: jane, fromKind: "person", toId: organization, toKind: "person")
        expectError(mismatch, code: .invalidParams, message: WireErrorMessage.linkKindMismatch)
        assertStoreHasNoLiveLinks(fixture)

        let created = await create(
            fixture, fromId: jane, fromKind: "person", toId: organization, toKind: "organization",
            note: "Board seat")
        guard case .link(_, _, let echo) = created else {
            return XCTFail("expected link echo, got \(String(describing: created))")
        }
        XCTAssertEqual(echo.kind, "organization")
        XCTAssertEqual(echo.otherId, organization)

        guard let fromOrg = await list(fixture, id: organization, kind: "organization")
        else { return XCTFail("links_list failed") }
        XCTAssertEqual(fromOrg.map(\.id), [echo.id])
        XCTAssertEqual(fromOrg.first?.kind, "person")
        XCTAssertEqual(fromOrg.first?.otherId, jane)
    }

    func testContactEventLinkRoundTripsSymmetrically() async {
        let fixture = await linkFixture()
        guard let jane = await contactID(fixture, query: "jane", name: "Jane Doe"),
              let gala = await eventID(fixture, title: "Museum Gala")
        else { return XCTFail("missing fixture records") }

        let created = await create(
            fixture, fromId: jane, fromKind: "person", toId: gala, toKind: "event",
            note: "Hosted the auction")
        guard case .link(_, _, let echo) = created else {
            return XCTFail("expected link echo, got \(String(describing: created))")
        }
        XCTAssertEqual(echo.kind, "event")
        XCTAssertEqual(echo.otherId, gala)

        guard let fromJane = await list(fixture, id: jane, kind: "person"),
              let fromGala = await list(fixture, id: gala, kind: "event")
        else { return XCTFail("links_list failed") }
        XCTAssertEqual(fromJane.map(\.id), [echo.id])
        XCTAssertEqual(fromJane.first?.kind, "event")
        XCTAssertEqual(fromJane.first?.otherId, gala)
        XCTAssertEqual(fromGala.map(\.id), [echo.id])
        XCTAssertEqual(fromGala.first?.kind, "person")
        XCTAssertEqual(fromGala.first?.otherId, jane)

        // The audit trail records the write with its durable referent.
        let entries = await fixture.audit.entries()
        XCTAssertTrue(entries.contains {
            $0.action == .addLinkedContact && $0.instanceID == echo.id
        })
    }

    func testContactPlaceLinkRoundTripsSymmetrically() async {
        let fixture = await linkFixture()
        guard let jane = await contactID(fixture, query: "jane", name: "Jane Doe"),
              let place = await placeID(fixture)
        else { return XCTFail("missing fixture records") }

        // Reversed argument order (place first) — links are symmetric, so
        // the app's place-side affordance and the contact-side one are the
        // same write.
        let created = await create(
            fixture, fromId: place, fromKind: "place", toId: jane, toKind: "person")
        guard case .link(_, _, let echo) = created else {
            return XCTFail("expected link echo, got \(String(describing: created))")
        }
        XCTAssertEqual(echo.kind, "person")
        XCTAssertEqual(echo.otherId, jane)

        guard let fromPlace = await list(fixture, id: place, kind: "place"),
              let fromJane = await list(fixture, id: jane, kind: "person")
        else { return XCTFail("links_list failed") }
        XCTAssertEqual(fromPlace.map(\.id), [echo.id])
        XCTAssertEqual(fromPlace.first?.kind, "person")
        XCTAssertEqual(fromJane.map(\.id), [echo.id])
        XCTAssertEqual(fromJane.first?.kind, "place")
        XCTAssertEqual(fromJane.first?.otherId, place)
    }

    func testEventEventLinkRoundTripsSymmetrically() async {
        let fixture = await linkFixture()
        let bookClub = Event(
            id: UUID(),
            eventKitID: nil,
            title: "Book Club",
            startDate: Date(timeIntervalSince1970: 1_760_200_000),
            endDate: Date(timeIntervalSince1970: 1_760_203_600))
        await MainActor.run { fixture.events.events.append(bookClub) }
        guard let gala = await eventID(fixture, title: "Museum Gala"),
              let club = await eventID(fixture, title: "Book Club")
        else { return XCTFail("missing fixture events") }

        let created = await create(
            fixture, fromId: gala, fromKind: "event", toId: club, toKind: "event")
        guard case .link(_, _, let echo) = created else {
            return XCTFail("expected link echo, got \(String(describing: created))")
        }
        XCTAssertEqual(echo.kind, "event")
        XCTAssertEqual(echo.otherId, club)

        guard let fromGala = await list(fixture, id: gala, kind: "event"),
              let fromClub = await list(fixture, id: club, kind: "event")
        else { return XCTFail("links_list failed") }
        XCTAssertEqual(fromGala.map(\.id), [echo.id])
        XCTAssertEqual(fromGala.first?.otherId, club)
        XCTAssertEqual(fromClub.map(\.id), [echo.id])
        XCTAssertEqual(fromClub.first?.otherId, gala)
    }

    func testEventPlaceLinkRoundTripsSymmetrically() async {
        let fixture = await linkFixture()
        guard let gala = await eventID(fixture, title: "Museum Gala"),
              let place = await placeID(fixture)
        else { return XCTFail("missing fixture records") }

        let created = await create(
            fixture, fromId: gala, fromKind: "event", toId: place, toKind: "place",
            note: "Venue")
        guard case .link(_, _, let echo) = created else {
            return XCTFail("expected link echo, got \(String(describing: created))")
        }
        XCTAssertEqual(echo.kind, "place")
        XCTAssertEqual(echo.otherId, place)

        guard let fromGala = await list(fixture, id: gala, kind: "event"),
              let fromPlace = await list(fixture, id: place, kind: "place")
        else { return XCTFail("links_list failed") }
        XCTAssertEqual(fromGala.map(\.id), [echo.id])
        XCTAssertEqual(fromGala.first?.kind, "place")
        XCTAssertEqual(fromPlace.map(\.id), [echo.id])
        XCTAssertEqual(fromPlace.first?.kind, "event")
        XCTAssertEqual(fromPlace.first?.otherId, gala)
    }

    // MARK: - Rejections (no app affordance / bad arguments)

    func testPlacePlacePairRejectedAndNothingWritten() async {
        let fixture = await linkFixture()
        let second = MapsPlace(
            id: UUID(), guideID: UUID(), name: "Second Stop",
            address: "34 Elm St", latitude: 30.28, longitude: -97.75)
        await MainActor.run { fixture.guides.places.append(second) }
        guard let first = await placeID(fixture) else { return XCTFail("no place") }

        let response = await create(
            fixture, fromId: first, fromKind: "place",
            toId: second.id.uuidString.lowercased(), toKind: "place")
        expectError(response, code: .invalidParams, message: WireErrorMessage.linkPairUnsupported)
        assertStoreHasNoLiveLinks(fixture)
    }

    func testUnknownKindRejected() async {
        let fixture = await linkFixture()
        guard let jane = await contactID(fixture, query: "jane", name: "Jane Doe")
        else { return XCTFail("no jane") }

        let response = await create(
            fixture, fromId: jane, fromKind: "person", toId: jane, toKind: "guide")
        expectError(response, code: .invalidParams, message: WireErrorMessage.invalidLinkKindArgument)

        let listed = await fixture.dispatcher.handle(.linksList(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            id: jane, kind: "guide", limit: nil, cursor: nil))
        expectError(listed, code: .invalidParams, message: WireErrorMessage.invalidLinkKindArgument)
        assertStoreHasNoLiveLinks(fixture)
    }

    func testSelfConnectionRejected() async {
        let fixture = await linkFixture()
        guard let jane = await contactID(fixture, query: "jane", name: "Jane Doe"),
              let gala = await eventID(fixture, title: "Museum Gala")
        else { return XCTFail("missing fixture records") }

        let contact = await create(
            fixture, fromId: jane, fromKind: "person", toId: jane, toKind: "person")
        expectError(contact, code: .invalidParams, message: WireErrorMessage.linkSelfNotAllowed)
        let event = await create(
            fixture, fromId: gala, fromKind: "event", toId: gala, toKind: "event")
        expectError(event, code: .invalidParams, message: WireErrorMessage.linkSelfNotAllowed)
        assertStoreHasNoLiveLinks(fixture)
    }

    /// The tags rule in connection form: a system-calendar-only event can't
    /// be connected — typed requiresAppAction, and NOTHING is minted or
    /// written to the store.
    func testUnadoptedEventRejectedAndMintsNothing() async {
        let fixture = await linkFixture()
        guard let jane = await contactID(fixture, query: "jane", name: "Jane Doe"),
              let dentist = await eventID(fixture, title: "Dentist")
        else { return XCTFail("missing fixture records") }
        XCTAssertTrue(dentist.hasPrefix("e-"), "the fixture's Dentist is system-only")

        let response = await create(
            fixture, fromId: jane, fromKind: "person", toId: dentist, toKind: "event")
        expectError(
            response, code: .requiresAppAction,
            message: WireErrorMessage.eventNeedsAppFirstToConnect)
        assertStoreHasNoLiveLinks(fixture)

        // Listing its connections is not an error — a record that can hold
        // none answers an empty page.
        let listed = await list(fixture, id: dentist, kind: "event")
        XCTAssertEqual(listed?.count, 0)
    }

    // MARK: - Remove: real tombstone, gone from lists, restorable

    func testRemoveTombstonesInTheRealStoreAndDisappearsFromLists() async {
        let fixture = await linkFixture()
        guard let gala = await eventID(fixture, title: "Museum Gala"),
              let place = await placeID(fixture)
        else { return XCTFail("missing fixture records") }
        guard case .link(_, _, let echo)? = await create(
            fixture, fromId: gala, fromKind: "event", toId: place, toKind: "place",
            note: "Venue")
        else { return XCTFail("create failed") }

        let removed = await fixture.dispatcher.handle(.linksDelete(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            linkId: echo.id, idempotencyToken: nil))
        guard case .acknowledged(_, _, let message) = removed else {
            return XCTFail("expected acknowledgement, got \(String(describing: removed))")
        }
        XCTAssertEqual(message, WireAckMessage.linkRemoved)

        // Gone from both endpoints' lists…
        let fromGala = await list(fixture, id: gala, kind: "event")
        let fromPlace = await list(fixture, id: place, kind: "place")
        XCTAssertEqual(fromGala?.count, 0)
        XCTAssertEqual(fromPlace?.count, 0)

        // …but the envelope survives ON DISK as a soft-deleted record: the
        // real engine still reads it back, deletedAt set, note preserved.
        let tombstone = (try? fixture.linkEngine.link(id: UUID(uuidString: echo.id)!)) ?? nil
        XCTAssertNotNil(tombstone?.deletedAt, "remove must soft-delete, not erase")
        XCTAssertEqual(tombstone?.note, "Venue")

        // A second remove finds no live connection.
        let again = await fixture.dispatcher.handle(.linksDelete(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            linkId: echo.id, idempotencyToken: nil))
        expectError(again, code: .notFound, message: WireErrorMessage.notFoundConnection)
    }

    func testRemovedGenericLinkIsRestorableFromRecentlyDeleted() async {
        let fixture = await linkFixture()
        guard let gala = await eventID(fixture, title: "Museum Gala"),
              let place = await placeID(fixture)
        else { return XCTFail("missing fixture records") }
        guard case .link(_, _, let echo)? = await create(
            fixture, fromId: gala, fromKind: "event", toId: place, toKind: "place",
            note: "Venue")
        else { return XCTFail("create failed") }
        _ = await fixture.dispatcher.handle(.linksDelete(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            linkId: echo.id, idempotencyToken: nil))

        let service = await MainActor.run {
            RecentlyDeletedService(
                audit: fixture.audit, contacts: fixture.contacts, events: fixture.events)
        }
        let items = await service.items()
        guard let row = items.first(where: { $0.id == echo.id }) else {
            return XCTFail("removed connection should appear in Recently Deleted")
        }
        XCTAssertTrue(row.canRestore)
        let restored = await service.restore(row)
        XCTAssertTrue(restored)

        let fromGala = await list(fixture, id: gala, kind: "event")
        XCTAssertEqual(fromGala?.map(\.id), [echo.id], "restore must revive the same connection")
    }

    func testRemoveUnknownConnectionIsNotFound() async {
        let fixture = await linkFixture()
        let response = await fixture.dispatcher.handle(.linksDelete(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            linkId: UUID().uuidString.lowercased(), idempotencyToken: nil))
        expectError(response, code: .notFound, message: WireErrorMessage.notFoundConnection)
    }

    // MARK: - Wire id → storage key, per kind

    /// The core new mapping: each wire id lands on the right SidecarKey in
    /// the REAL envelope — the contact's GuessWho UUID, the event's record
    /// UUID — never a localID or URL form.
    func testWireIdsResolveToTheRightEndpointKeys() async {
        let fixture = await linkFixture()
        guard let jane = await contactID(fixture, query: "jane", name: "Jane Doe"),
              let gala = await eventID(fixture, title: "Museum Gala")
        else { return XCTFail("missing fixture records") }
        guard case .link(_, _, let echo)? = await create(
            fixture, fromId: jane, fromKind: "person", toId: gala, toKind: "event")
        else { return XCTFail("create failed") }

        let stored = (try? fixture.linkEngine.link(id: UUID(uuidString: echo.id)!)) ?? nil
        guard let stored else { return XCTFail("link missing from the real store") }
        let endpoints = Set([stored.endpointA, stored.endpointB])
        XCTAssertEqual(endpoints, Set([
            SidecarKey(kind: .contact, id: Sentinels.guessWhoUUID),
            SidecarKey(kind: .event, id: gala),
        ]))
    }

    // MARK: - Exclusions

    /// The four focused exclusions hold on the new outputs — including the
    /// REAL engine's `modifiedBy`, which is the planted device-id sentinel
    /// here, so a Link field leaking through the DTO would trip this.
    func testExcludedFieldsNeverAppearInLinkOutputs() async {
        let fixture = await linkFixture()
        guard let jane = await contactID(fixture, query: "jane", name: "Jane Doe"),
              let gala = await eventID(fixture, title: "Museum Gala"),
              let place = await placeID(fixture)
        else { return XCTFail("missing fixture records") }

        var outputs: [WireResponse] = []
        if let created = await create(
            fixture, fromId: jane, fromKind: "person", toId: gala, toKind: "event",
            note: "Hosted the auction") {
            outputs.append(created)
        }
        if let created = await create(
            fixture, fromId: place, fromKind: "place", toId: jane, toKind: "person") {
            outputs.append(created)
        }
        for (id, kind) in [(jane, "person"), (gala, "event"), (place, "place")] {
            if let response = await fixture.dispatcher.handle(.linksList(
                helperId: Fixture.helper, messageId: TestMessageID.next(),
                id: id, kind: kind, limit: nil, cursor: nil)) {
                outputs.append(response)
            }
        }
        XCTAssertEqual(outputs.count, 5)
        for response in outputs {
            for surface in [response.wireJSON, response.agentVisibleText] {
                XCTAssertFalse(surface.contains(Sentinels.localID), "local id leaked")
                XCTAssertFalse(surface.contains(Sentinels.deviceID), "modifiedBy device id leaked")
                XCTAssertFalse(surface.contains(Sentinels.appleNote), "Apple note leaked")
                XCTAssertFalse(surface.lowercased().contains("guesswho://"), "identity URL leaked")
            }
        }
    }

    // MARK: - Mint-during-link (contact↔event / contact↔place)

    /// links_create from a NEVER-reconciled contact to an event: the write
    /// mints the contact's identity (deterministically, so the pre-mint
    /// wire id IS the minted id), and the link lands in the real store
    /// keyed on that minted identity — visible from both endpoints.
    func testEventLinkFromUnreconciledContactMintsDeterministically() async {
        let fixture = await linkFixture()
        guard let fresh = await contactID(fixture, query: "fresh", name: "Fresh Face"),
              let gala = await eventID(fixture, title: "Museum Gala")
        else { return XCTFail("missing fixture records") }
        let preMint = await MainActor.run {
            fixture.contacts.contacts.first { $0.displayName == "Fresh Face" }?
                .contactID.restorationToken.guessWhoID
        }
        XCTAssertNil(preMint, "Fresh Face must start unreconciled")

        guard case .link(_, _, let echo)? = await create(
            fixture, fromId: fresh, fromKind: "person", toId: gala, toKind: "event",
            note: "First outing")
        else { return XCTFail("create failed") }

        // The mint happened, and it minted the SAME id the wire handed out
        // before the write (Rev2's deterministic mint).
        let (minted, mintCount) = await MainActor.run {
            (fixture.contacts.contacts.first { $0.displayName == "Fresh Face" }?
                .contactID.restorationToken.guessWhoID,
             fixture.contacts.mintCount)
        }
        XCTAssertEqual(minted, fresh, "the pre-mint wire id is the minted id")
        XCTAssertEqual(mintCount, 1)

        // The REAL envelope is keyed on the minted identity — the post-mint
        // verify's whole point: the link is reachable from the card, not
        // stranded on a never-stamped key.
        let stored = (try? fixture.linkEngine.link(id: UUID(uuidString: echo.id)!)) ?? nil
        XCTAssertEqual(
            Set([stored?.endpointA, stored?.endpointB].compactMap { $0 }),
            Set([SidecarKey(kind: .contact, id: fresh), SidecarKey(kind: .event, id: gala)]))

        guard let fromFresh = await list(fixture, id: fresh, kind: "person"),
              let fromGala = await list(fixture, id: gala, kind: "event")
        else { return XCTFail("links_list failed") }
        XCTAssertEqual(fromFresh.map(\.id), [echo.id])
        XCTAssertEqual(fromFresh.first?.otherId, gala)
        XCTAssertEqual(fromGala.map(\.id), [echo.id])
        XCTAssertEqual(fromGala.first?.otherId, fresh, "the far id is the now-minted contact id")
        XCTAssertEqual(fromGala.first?.kind, "person")
    }

    /// The place twin of the mint-during-link path.
    func testPlaceLinkFromUnreconciledContactMintsDeterministically() async {
        let fixture = await linkFixture()
        guard let fresh = await contactID(fixture, query: "fresh", name: "Fresh Face"),
              let place = await placeID(fixture)
        else { return XCTFail("missing fixture records") }

        guard case .link(_, _, let echo)? = await create(
            fixture, fromId: fresh, fromKind: "person", toId: place, toKind: "place")
        else { return XCTFail("create failed") }

        let minted = await MainActor.run {
            fixture.contacts.contacts.first { $0.displayName == "Fresh Face" }?
                .contactID.restorationToken.guessWhoID
        }
        XCTAssertEqual(minted, fresh)

        let stored = (try? fixture.linkEngine.link(id: UUID(uuidString: echo.id)!)) ?? nil
        XCTAssertEqual(
            Set([stored?.endpointA, stored?.endpointB].compactMap { $0 }),
            Set([SidecarKey(kind: .contact, id: fresh), SidecarKey(kind: .place, id: place)]))

        guard let fromFresh = await list(fixture, id: fresh, kind: "person"),
              let fromPlace = await list(fixture, id: place, kind: "place")
        else { return XCTFail("links_list failed") }
        XCTAssertEqual(fromFresh.map(\.id), [echo.id])
        XCTAssertEqual(fromFresh.first?.kind, "place")
        XCTAssertEqual(fromPlace.map(\.id), [echo.id])
        XCTAssertEqual(fromPlace.first?.otherId, fresh)
    }

    /// The losing-mint race on the single-contact path: a concurrent
    /// first-writer's mint wins the card while our link write lands on the
    /// losing identity. addContactRecordLink's post-mint verify must catch
    /// it, remove the stale link from the REAL store, and retry onto the
    /// card's canonical identity — no half-orphan survives.
    func testLosingMintDuringEventLinkRetriesOntoCanonicalIdentity() async {
        let fixture = await linkFixture()
        guard let fresh = await contactID(fixture, query: "fresh", name: "Fresh Face"),
              let gala = await eventID(fixture, title: "Museum Gala")
        else { return XCTFail("missing fixture records") }
        await MainActor.run { fixture.contacts.simulateLosingMintOnce = true }

        guard case .link(_, _, let echo)? = await create(
            fixture, fromId: fresh, fromKind: "person", toId: gala, toKind: "event")
        else { return XCTFail("create failed") }

        // The card carries the WINNING (other writer's) identity, not the
        // deterministic preview our first attempt keyed on.
        let winning = await MainActor.run {
            fixture.contacts.contacts.first { $0.displayName == "Fresh Face" }?
                .contactID.restorationToken.guessWhoID
        }
        guard let winning else { return XCTFail("the race must leave a minted identity") }
        XCTAssertNotEqual(winning, fresh, "the simulated race stamps a different identity")

        // Exactly ONE live link in the real store, keyed on the canonical
        // identity — the losing-key link was removed, not stranded.
        let liveContactEndpoints = (try? await fixture.linkEngine.linkedEndpoints(ofKind: .contact)) ?? []
        XCTAssertEqual(liveContactEndpoints, [SidecarKey(kind: .contact, id: winning)])
        let stored = (try? fixture.linkEngine.link(id: UUID(uuidString: echo.id)!)) ?? nil
        XCTAssertEqual(
            Set([stored?.endpointA, stored?.endpointB].compactMap { $0 }),
            Set([SidecarKey(kind: .contact, id: winning), SidecarKey(kind: .event, id: gala)]))

        // The agent's original (deterministic) wire id STILL resolves — the
        // derivation matches the card — and lists the retried link.
        guard let fromFresh = await list(fixture, id: fresh, kind: "person"),
              let fromGala = await list(fixture, id: gala, kind: "event")
        else { return XCTFail("links_list failed") }
        XCTAssertEqual(fromFresh.map(\.id), [echo.id])
        XCTAssertEqual(fromGala.map(\.id), [echo.id])
        XCTAssertEqual(fromGala.first?.otherId, winning)
    }

    // MARK: - Write gating, budget, idempotency

    func testLinksCreateRejectedUnderReadOnlyWhileListStaysAvailable() async {
        let fixture = await Fixture.make() // read-only: the shipping default
        await MainActor.run { fixture.contacts.linkEngine = fixture.linkEngine }
        guard let jane = await contactID(fixture, query: "jane", name: "Jane Doe"),
              let gala = await eventID(fixture, title: "Museum Gala")
        else { return XCTFail("missing fixture records") }

        let write = await create(
            fixture, fromId: jane, fromKind: "person", toId: gala, toKind: "event")
        expectError(write, code: .readOnly)
        assertStoreHasNoLiveLinks(fixture)

        // links_list is a read — allowed under read-only, and the write
        // tools are hidden from listTools while links_list stays visible.
        let listed = await list(fixture, id: jane, kind: "person")
        XCTAssertEqual(listed?.count, 0)
        let toolList = await fixture.dispatcher.handle(
            .listTools(helperId: Fixture.helper, messageId: "m"))
        guard case .toolList(_, _, let tools, _) = toolList else { return XCTFail("expected toolList") }
        let names = Set(tools.map(\.name))
        XCTAssertTrue(names.contains(MCPTool.linksList.rawValue))
        XCTAssertFalse(names.contains(MCPTool.linksCreate.rawValue))
        XCTAssertFalse(names.contains(MCPTool.linksDelete.rawValue))
    }

    func testRetriedCreateWithSameTokenDoesNotDuplicate() async {
        let fixture = await linkFixture()
        guard let jane = await contactID(fixture, query: "jane", name: "Jane Doe"),
              let gala = await eventID(fixture, title: "Museum Gala")
        else { return XCTFail("missing fixture records") }

        let first = await create(
            fixture, fromId: jane, fromKind: "person", toId: gala, toKind: "event",
            note: "Hosted the auction", token: "retry-1")
        guard case .link(_, _, let original)? = first else { return XCTFail("create failed") }
        let second = await create(
            fixture, fromId: jane, fromKind: "person", toId: gala, toKind: "event",
            note: "Hosted the auction", token: "retry-1")
        guard case .link(_, _, let replayed)? = second else {
            return XCTFail("retry should replay the echo")
        }
        XCTAssertEqual(replayed.id, original.id, "a retried token replays, not re-applies")

        let fromJane = await list(fixture, id: jane, kind: "person")
        XCTAssertEqual(fromJane?.count, 1, "exactly one connection in the real store")
    }
}
