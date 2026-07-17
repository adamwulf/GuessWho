import XCTest
import GuessWhoSync
import GuessWhoMCPCore
import GuessWhoMCPWire

/// Deterministic-identity unit behavior (Revision 2): the wire id scheme
/// and the package's deterministic mint agree by construction.
final class DeterministicIdentityTests: XCTestCase {

    @MainActor
    func testDeterministicMintIsAValidStableUUID() {
        let fresh = Fixture.freshFace()
        let first = fresh.deterministicGuessWhoID
        let second = Fixture.freshFace().deterministicGuessWhoID
        XCTAssertEqual(first, second, "same inputs must derive the same UUID")
        XCTAssertNotNil(UUID(uuidString: first), "must be a real UUID (the GuessWho id format)")
        XCTAssertEqual(first, first.lowercased(), "canonical lowercase")
        // Distinct contacts derive distinct UUIDs.
        XCTAssertNotEqual(first, Fixture.janeDoe().deterministicGuessWhoID)
    }

    /// The pre-mint id embeds the display name: if system unification
    /// re-points the localID at a DIFFERENT person, the id stops resolving
    /// (the structural stale-localID guard) — asserted end-to-end here.
    func testPreMintIdStopsResolvingWhenTheContactIsRepointed() async {
        let fixture = await Fixture.make()
        await MainActor.run {
            fixture.gates.mcpAccess = .readWrite
            fixture.gates.cliAccess = .readWrite
        }
        let search = await fixture.dispatcher.handle(.contactsSearch(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            query: "fresh", limit: nil, cursor: nil))
        guard case .contactPage(_, _, let page) = search,
              let preMintID = page.items.first(where: { $0.name == "Fresh Face" })?.id
        else { return XCTFail("expected the fresh contact") }

        await MainActor.run {
            guard let index = fixture.contacts.contacts.firstIndex(where: {
                $0.contactID.restorationToken.localID == "ABPerson-LOCAL-FRESH-88"
            }) else { return }
            var repointed = fixture.contacts.contacts[index]
            repointed.givenName = "Somebody"
            repointed.familyName = "Else"
            fixture.contacts.contacts[index] = repointed
        }

        let write = await fixture.dispatcher.handle(.contactsAddNote(
            helperId: Fixture.helper, messageId: "m",
            contactId: preMintID, body: "wrong person", idempotencyToken: nil))
        XCTAssertEqual(write?.errorPayload?.code, .notFound,
                       "a re-pointed pre-mint id must stop resolving, never misdirect a write")
        let allBodies = await MainActor.run {
            fixture.contacts.notesByEffectiveID.values.flatMap { $0 }.map(\.body)
        }
        XCTAssertFalse(allBodies.contains("wrong person"))
    }

    /// System-only events ride a DERIVED id (never the raw calendar id),
    /// and it keeps resolving after the user adopts the event in the app.
    func testSystemEventIdIsDerivedAndSurvivesAdoption() async {
        let fixture = await Fixture.make()
        let list = await fixture.dispatcher.handle(.eventsList(
            helperId: Fixture.helper, messageId: "m",
            startDate: "2025-01-01T00:00:00Z", endDate: "2025-12-01T00:00:00Z",
            limit: nil, cursor: nil))
        guard case .eventPage(_, _, let page) = list,
              let dentist = page.items.first(where: { $0.title == "Dentist" })
        else { return XCTFail("expected the system-only event") }
        XCTAssertFalse(dentist.id.contains("EK-SENTINEL"), "raw calendar id must not ride")
        XCTAssertTrue(dentist.id.hasPrefix("e-"))

        // The user opens the event in the app: a record now exists for the
        // calendar id. The SAME wire id keeps resolving, now to the record.
        await MainActor.run {
            let adopted = Event(
                id: UUID(),
                eventKitID: "EK-SENTINEL-42",
                title: "Dentist",
                startDate: Date(timeIntervalSince1970: 1_760_100_000),
                endDate: Date(timeIntervalSince1970: 1_760_103_600))
            fixture.events.events.append(adopted)
            fixture.events.eventKitOnlyEvents.removeValue(forKey: "EK-SENTINEL-42")
        }
        let after = await fixture.dispatcher.handle(.eventsGet(
            helperId: Fixture.helper, messageId: "m2", eventId: dentist.id))
        guard case .event(_, _, let event) = after else {
            return XCTFail("the derived id should still resolve after adoption; got \(String(describing: after))")
        }
        XCTAssertEqual(event.title, "Dentist")
    }
}
