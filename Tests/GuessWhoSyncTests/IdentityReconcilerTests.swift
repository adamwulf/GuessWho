import Foundation
import Testing
@testable import GuessWhoSync
import GuessWhoSyncTesting

@Suite("IdentityReconciler")
struct IdentityReconcilerTests {
    private let t1 = Date(timeIntervalSince1970: 1_700_000_000)
    private let t2 = Date(timeIntervalSince1970: 1_700_000_500)
    private let t3 = Date(timeIntervalSince1970: 1_700_001_000)

    private let alpha = "11111111-1111-4111-8111-111111111111"
    private let beta  = "22222222-2222-4222-8222-222222222222"
    private let gamma = "33333333-3333-4333-8333-333333333333"

    private func makeSync(
        contacts: InMemoryContactStore,
        sidecars: InMemorySidecarStore,
        deviceID: String = "device-test"
    ) -> GuessWhoSync {
        GuessWhoSync(
            contacts: contacts,
            events: InMemoryEventStore(),
            sidecars: sidecars,
            deviceID: deviceID
        )
    }

    private func guessWhoURLs(in contact: Contact) -> [String] {
        contact.urlAddresses
            .map(\.value)
            .filter { $0.hasPrefix("guesswho://contact/") }
    }

    // MARK: - §9.3

    @Test
    func caseA_assignsFreshUUID() async throws {
        let contact = Contact(localID: "C1", givenName: "Ada")
        let contacts = InMemoryContactStore(contacts: [contact])
        let sidecars = InMemorySidecarStore()
        let sync = makeSync(contacts: contacts, sidecars: sidecars)

        let report = try await sync.reconcileContactIdentities()

        #expect(report.contactOutcomes.count == 1)
        let outcome = report.contactOutcomes[0]
        #expect(outcome.localID == "C1")
        #expect(outcome.assignedUUID != nil)
        #expect(outcome.removedMalformedURLs.isEmpty)
        #expect(outcome.mergedLoserUUIDs.isEmpty)
        #expect(outcome.errors.isEmpty)

        let saved = try #require(try await contacts.fetch(localID: "C1"))
        let gwURLs = guessWhoURLs(in: saved)
        #expect(gwURLs.count == 1)
        let uuid = try #require(SidecarKey.parseGuessWhoContactURL(gwURLs[0]))
        #expect(uuid == outcome.assignedUUID)
        #expect(uuid == uuid.lowercased())

        let gwLabeled = saved.urlAddresses.first { $0.value.hasPrefix("guesswho://contact/") }
        #expect(gwLabeled?.label == "GuessWho")
    }

    @Test
    func caseA_withMalformedURLsThatNameExistingSidecars() async throws {
        let contact = Contact(
            localID: "C1",
            urlAddresses: [
                LabeledValue(label: "GuessWho", value: "guesswho://contact/garbage"),
            ]
        )
        let contacts = InMemoryContactStore(contacts: [contact])
        let sidecars = InMemorySidecarStore()
        let garbageKey = SidecarKey(kind: .contact, id: "garbage")
        try sidecars.write(
            SidecarEnvelope(entityID: "garbage", fields: [
                "nickname": SidecarCell(value: .string("ghost"), modifiedAt: t1, modifiedBy: "device-X"),
            ]),
            at: garbageKey
        )

        let sync = makeSync(contacts: contacts, sidecars: sidecars)
        let report = try await sync.reconcileContactIdentities()

        let outcome = report.contactOutcomes[0]
        #expect(outcome.assignedUUID != nil)
        #expect(outcome.removedMalformedURLs == ["guesswho://contact/garbage"])

        let saved = try #require(try await contacts.fetch(localID: "C1"))
        let gwURLs = guessWhoURLs(in: saved)
        #expect(gwURLs.count == 1)
        #expect(!gwURLs.contains("guesswho://contact/garbage"))

        #expect(try sidecars.read(garbageKey) != nil)
        #expect(report.orphanSidecars.contains(garbageKey))
    }

    @Test
    func caseB_singleValidIsNoOp() async throws {
        let url = LabeledValue(label: "GuessWho", value: "guesswho://contact/" + alpha)
        let original = Contact(localID: "C1", givenName: "Ada", urlAddresses: [url])
        let contacts = InMemoryContactStore(contacts: [original])
        let sidecars = InMemorySidecarStore()
        let sync = makeSync(contacts: contacts, sidecars: sidecars)

        let report = try await sync.reconcileContactIdentities()

        let outcome = report.contactOutcomes[0]
        #expect(outcome.assignedUUID == nil)
        #expect(outcome.mergedLoserUUIDs.isEmpty)
        #expect(outcome.removedMalformedURLs.isEmpty)
        #expect(outcome.errors.isEmpty)

        let saved = try #require(try await contacts.fetch(localID: "C1"))
        #expect(saved == original)
    }

    @Test
    func caseC_validKeptAndMalformedRemoved() async throws {
        let contact = Contact(
            localID: "C1",
            urlAddresses: [
                LabeledValue(label: "GuessWho", value: "guesswho://contact/" + alpha),
                LabeledValue(label: "GuessWho", value: "guesswho://contact/garbage"),
                LabeledValue(label: "home", value: "https://example.com"),
            ]
        )
        let contacts = InMemoryContactStore(contacts: [contact])
        let sidecars = InMemorySidecarStore()
        let sync = makeSync(contacts: contacts, sidecars: sidecars)

        let report = try await sync.reconcileContactIdentities()

        let outcome = report.contactOutcomes[0]
        #expect(outcome.assignedUUID == nil)
        #expect(outcome.mergedLoserUUIDs.isEmpty)
        #expect(outcome.removedMalformedURLs == ["guesswho://contact/garbage"])

        let saved = try #require(try await contacts.fetch(localID: "C1"))
        let gwURLs = guessWhoURLs(in: saved)
        #expect(gwURLs == ["guesswho://contact/" + alpha])
        #expect(saved.urlAddresses.contains(LabeledValue(label: "home", value: "https://example.com")))
    }

    @Test
    func caseD_twoValidLexSmallestWinsAndLoserSidecarMerged() async throws {
        let contact = Contact(
            localID: "C1",
            urlAddresses: [
                LabeledValue(label: "GuessWho", value: "guesswho://contact/" + beta),
                LabeledValue(label: "GuessWho", value: "guesswho://contact/" + alpha),
            ]
        )
        let contacts = InMemoryContactStore(contacts: [contact])
        let sidecars = InMemorySidecarStore()
        try sidecars.write(
            SidecarEnvelope(entityID: alpha, fields: [
                "nickname": SidecarCell(value: .string("Bear"), modifiedAt: t1, modifiedBy: "device-A"),
            ]),
            at: SidecarKey(kind: .contact, id: alpha)
        )
        try sidecars.write(
            SidecarEnvelope(entityID: beta, fields: [
                "notes": SidecarCell(value: .string("met"), modifiedAt: t1, modifiedBy: "device-B"),
            ]),
            at: SidecarKey(kind: .contact, id: beta)
        )

        let sync = makeSync(contacts: contacts, sidecars: sidecars)
        let report = try await sync.reconcileContactIdentities()

        let outcome = report.contactOutcomes[0]
        #expect(outcome.assignedUUID == nil)
        #expect(outcome.mergedLoserUUIDs == [beta])
        #expect(outcome.errors.isEmpty)

        let saved = try #require(try await contacts.fetch(localID: "C1"))
        let gwURLs = guessWhoURLs(in: saved)
        #expect(gwURLs == ["guesswho://contact/" + alpha])

        let winner = try #require(try sidecars.read(SidecarKey(kind: .contact, id: alpha)))
        #expect(winner.entityID == alpha)
        #expect(Set(winner.fields.keys) == ["nickname", "notes"])

        #expect(try sidecars.read(SidecarKey(kind: .contact, id: beta)) == nil)
    }

    @Test
    func caseD_perFieldLWWAcrossOverlappingAndDisjointFields() async throws {
        let contact = Contact(
            localID: "C1",
            urlAddresses: [
                LabeledValue(label: "GuessWho", value: "guesswho://contact/" + alpha),
                LabeledValue(label: "GuessWho", value: "guesswho://contact/" + beta),
            ]
        )
        let contacts = InMemoryContactStore(contacts: [contact])
        let sidecars = InMemorySidecarStore()
        try sidecars.write(
            SidecarEnvelope(entityID: alpha, fields: [
                "nickname": SidecarCell(value: .string("Bear"), modifiedAt: t1, modifiedBy: "device-A"),
                "color": SidecarCell(value: .string("blue"), modifiedAt: t2, modifiedBy: "device-A"),
            ]),
            at: SidecarKey(kind: .contact, id: alpha)
        )
        try sidecars.write(
            SidecarEnvelope(entityID: beta, fields: [
                "nickname": SidecarCell(value: .string("Bear-cub"), modifiedAt: t2, modifiedBy: "device-B"),
                "notes": SidecarCell(value: .string("met"), modifiedAt: t1, modifiedBy: "device-B"),
            ]),
            at: SidecarKey(kind: .contact, id: beta)
        )

        let sync = makeSync(contacts: contacts, sidecars: sidecars)
        _ = try await sync.reconcileContactIdentities()

        let winner = try #require(try sidecars.read(SidecarKey(kind: .contact, id: alpha)))
        #expect(Set(winner.fields.keys) == ["nickname", "color", "notes"])

        let nickCell = try #require(winner.fields["nickname"])
        #expect(nickCell.value == .string("Bear-cub"))
        #expect(nickCell.modifiedAt == t2)
        #expect(nickCell.modifiedBy == "device-B")
        #expect(nickCell.deletedAt == nil)

        let colorCell = try #require(winner.fields["color"])
        #expect(colorCell.value == .string("blue"))
        #expect(colorCell.deletedAt == nil)

        let notesCell = try #require(winner.fields["notes"])
        #expect(notesCell.value == .string("met"))
        #expect(notesCell.deletedAt == nil)

        #expect(try sidecars.read(SidecarKey(kind: .contact, id: beta)) == nil)
    }

    @Test
    func caseD_threeValidLexSmallestWinsAndBothLosersMerged() async throws {
        let contact = Contact(
            localID: "C1",
            urlAddresses: [
                LabeledValue(label: "GuessWho", value: "guesswho://contact/" + gamma),
                LabeledValue(label: "GuessWho", value: "guesswho://contact/" + alpha),
                LabeledValue(label: "GuessWho", value: "guesswho://contact/" + beta),
            ]
        )
        let contacts = InMemoryContactStore(contacts: [contact])
        let sidecars = InMemorySidecarStore()
        try sidecars.write(
            SidecarEnvelope(entityID: alpha, fields: [
                "fieldA": SidecarCell(value: .string("a"), modifiedAt: t1, modifiedBy: "device-A"),
            ]),
            at: SidecarKey(kind: .contact, id: alpha)
        )
        try sidecars.write(
            SidecarEnvelope(entityID: beta, fields: [
                "fieldB": SidecarCell(value: .string("b"), modifiedAt: t1, modifiedBy: "device-B"),
            ]),
            at: SidecarKey(kind: .contact, id: beta)
        )
        try sidecars.write(
            SidecarEnvelope(entityID: gamma, fields: [
                "fieldC": SidecarCell(value: .string("c"), modifiedAt: t1, modifiedBy: "device-C"),
            ]),
            at: SidecarKey(kind: .contact, id: gamma)
        )

        let sync = makeSync(contacts: contacts, sidecars: sidecars)
        let report = try await sync.reconcileContactIdentities()

        let outcome = report.contactOutcomes[0]
        #expect(outcome.mergedLoserUUIDs == [beta, gamma])

        let saved = try #require(try await contacts.fetch(localID: "C1"))
        #expect(guessWhoURLs(in: saved) == ["guesswho://contact/" + alpha])

        let winner = try #require(try sidecars.read(SidecarKey(kind: .contact, id: alpha)))
        #expect(Set(winner.fields.keys) == ["fieldA", "fieldB", "fieldC"])
        #expect(try sidecars.read(SidecarKey(kind: .contact, id: beta)) == nil)
        #expect(try sidecars.read(SidecarKey(kind: .contact, id: gamma)) == nil)
    }

    @Test
    func idempotentOnStableContact() async throws {
        let url = LabeledValue(label: "GuessWho", value: "guesswho://contact/" + alpha)
        let contact = Contact(localID: "C1", givenName: "Ada", urlAddresses: [url])
        let contacts = InMemoryContactStore(contacts: [contact])
        let sidecars = InMemorySidecarStore()
        let sync = makeSync(contacts: contacts, sidecars: sidecars)

        _ = try await sync.reconcileContactIdentities()
        let snapshot = try #require(try await contacts.fetch(localID: "C1"))

        let report = try await sync.reconcileContactIdentities()
        let outcome = report.contactOutcomes[0]
        #expect(outcome.assignedUUID == nil)
        #expect(outcome.mergedLoserUUIDs.isEmpty)
        #expect(outcome.errors.isEmpty)

        let after = try #require(try await contacts.fetch(localID: "C1"))
        #expect(after == snapshot)
    }

    // MARK: - §9.6

    @Test
    func combined_twoDevicesIndependentUUIDsConverge() async throws {
        let contact = Contact(
            localID: "C1",
            urlAddresses: [
                LabeledValue(label: "GuessWho", value: "guesswho://contact/" + beta),
                LabeledValue(label: "GuessWho", value: "guesswho://contact/" + alpha),
            ]
        )
        let contacts = InMemoryContactStore(contacts: [contact])
        let sidecars = InMemorySidecarStore()
        try sidecars.write(
            SidecarEnvelope(entityID: alpha, fields: [
                "nickname": SidecarCell(value: .string("from-A"), modifiedAt: t1, modifiedBy: "device-A"),
                "shared": SidecarCell(value: .string("A-version"), modifiedAt: t1, modifiedBy: "device-A"),
            ]),
            at: SidecarKey(kind: .contact, id: alpha)
        )
        try sidecars.write(
            SidecarEnvelope(entityID: beta, fields: [
                "notes": SidecarCell(value: .string("from-B"), modifiedAt: t2, modifiedBy: "device-B"),
                "shared": SidecarCell(value: .string("B-version"), modifiedAt: t3, modifiedBy: "device-B"),
            ]),
            at: SidecarKey(kind: .contact, id: beta)
        )

        let sync = makeSync(contacts: contacts, sidecars: sidecars)
        _ = try await sync.reconcileContactIdentities()

        let saved = try #require(try await contacts.fetch(localID: "C1"))
        #expect(guessWhoURLs(in: saved) == ["guesswho://contact/" + alpha])

        let winner = try #require(try sidecars.read(SidecarKey(kind: .contact, id: alpha)))
        #expect(Set(winner.fields.keys) == ["nickname", "notes", "shared"])

        let sharedCell = try #require(winner.fields["shared"])
        #expect(sharedCell.value == .string("B-version"))
        #expect(sharedCell.modifiedAt == t3)
        #expect(sharedCell.modifiedBy == "device-B")
        #expect(sharedCell.deletedAt == nil)

        #expect(try sidecars.read(SidecarKey(kind: .contact, id: beta)) == nil)
    }

    // MARK: - Duplicate-UUID and case-canonicalization

    @Test
    func caseB_duplicateSameUUIDCollapsesToSingleURL() async throws {
        let url = "guesswho://contact/" + alpha
        let contact = Contact(
            localID: "C1",
            urlAddresses: [
                LabeledValue(label: "GuessWho", value: url),
                LabeledValue(label: "GuessWho", value: url),
            ]
        )
        let contacts = InMemoryContactStore(contacts: [contact])
        let sidecars = InMemorySidecarStore()
        try sidecars.write(
            SidecarEnvelope(entityID: alpha, fields: [
                "nickname": SidecarCell(value: .string("Bear"), modifiedAt: t1, modifiedBy: "device-A"),
            ]),
            at: SidecarKey(kind: .contact, id: alpha)
        )

        let sync = makeSync(contacts: contacts, sidecars: sidecars)
        let report = try await sync.reconcileContactIdentities()

        let outcome = report.contactOutcomes[0]
        #expect(outcome.assignedUUID == nil)
        #expect(outcome.mergedLoserUUIDs.isEmpty)
        #expect(outcome.removedMalformedURLs.isEmpty)
        #expect(outcome.errors.isEmpty)

        let saved = try #require(try await contacts.fetch(localID: "C1"))
        let gwURLs = guessWhoURLs(in: saved)
        #expect(gwURLs == [url])

        let kept = try #require(try sidecars.read(SidecarKey(kind: .contact, id: alpha)))
        #expect(kept.fields.keys.contains("nickname"))
        #expect(!report.orphanSidecars.contains(SidecarKey(kind: .contact, id: alpha)))
    }

    @Test
    func caseB_duplicateMixedCaseSameUUIDCollapsesToSingleURL() async throws {
        // [<UUID-X-upper>, <uuid-x-lower>] — same canonical UUID in two cases.
        // Must collapse to ONE URL via the duplicate path, NOT trigger Case D.
        let lower = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
        let upper = lower.uppercased()
        let contact = Contact(
            localID: "C1",
            urlAddresses: [
                LabeledValue(label: "GuessWho", value: "guesswho://contact/" + upper),
                LabeledValue(label: "GuessWho", value: "guesswho://contact/" + lower),
            ]
        )
        let contacts = InMemoryContactStore(contacts: [contact])
        let sidecars = InMemorySidecarStore()
        try sidecars.write(
            SidecarEnvelope(entityID: lower, fields: [
                "nickname": SidecarCell(value: .string("Bear"), modifiedAt: t1, modifiedBy: "device-A"),
            ]),
            at: SidecarKey(kind: .contact, id: lower)
        )

        let sync = makeSync(contacts: contacts, sidecars: sidecars)
        let report = try await sync.reconcileContactIdentities()

        let outcome = report.contactOutcomes[0]
        #expect(outcome.assignedUUID == nil)
        #expect(outcome.mergedLoserUUIDs.isEmpty)
        #expect(outcome.errors.isEmpty)

        let saved = try #require(try await contacts.fetch(localID: "C1"))
        let gwURLs = guessWhoURLs(in: saved)
        #expect(gwURLs.count == 1)
        #expect(SidecarKey.parseGuessWhoContactURL(gwURLs[0]) == lower)

        let kept = try #require(try sidecars.read(SidecarKey(kind: .contact, id: lower)))
        #expect(kept.fields.keys.contains("nickname"))
    }

    @Test
    func sidecarStoreIsCaseInsensitiveOnUUIDKeys() throws {
        let sidecars = InMemorySidecarStore()
        // A UUID with hex letters so uppercased != lowercased.
        let upper = "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEFFFF"
        let lower = upper.lowercased()
        let upperKey = SidecarKey(kind: .contact, id: upper)
        let lowerKey = SidecarKey(kind: .contact, id: lower)

        try sidecars.write(
            SidecarEnvelope(entityID: upper, fields: [
                "nickname": SidecarCell(value: .string("Bear"), modifiedAt: t1, modifiedBy: "device-A"),
            ]),
            at: upperKey
        )

        let viaLower = try #require(try sidecars.read(lowerKey))
        #expect(viaLower.fields.keys.contains("nickname"))

        let keys = try sidecars.allKeys()
        #expect(keys.count == 1)
        #expect(keys[0].id == lower)
    }

    @Test
    func caseD_mixedCaseUUIDsCanonicalizeAndWinnerSurvives() async throws {
        // Two UUIDs with hex letters; aa... < bb... lexicographically when both lowercased.
        let lowerAlpha = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        let lowerBeta  = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
        let upperAlpha = lowerAlpha.uppercased()
        // Feed alpha uppercased and beta lowercased — alpha must still win after canonicalization.
        let contact = Contact(
            localID: "C1",
            urlAddresses: [
                LabeledValue(label: "GuessWho", value: "guesswho://contact/" + upperAlpha),
                LabeledValue(label: "GuessWho", value: "guesswho://contact/" + lowerBeta),
            ]
        )
        let contacts = InMemoryContactStore(contacts: [contact])
        let sidecars = InMemorySidecarStore()
        try sidecars.write(
            SidecarEnvelope(entityID: lowerAlpha, fields: [
                "nickname": SidecarCell(value: .string("Bear"), modifiedAt: t1, modifiedBy: "device-A"),
            ]),
            at: SidecarKey(kind: .contact, id: lowerAlpha)
        )
        try sidecars.write(
            SidecarEnvelope(entityID: lowerBeta, fields: [
                "notes": SidecarCell(value: .string("met"), modifiedAt: t1, modifiedBy: "device-B"),
            ]),
            at: SidecarKey(kind: .contact, id: lowerBeta)
        )

        let sync = makeSync(contacts: contacts, sidecars: sidecars)
        let report = try await sync.reconcileContactIdentities()

        let outcome = report.contactOutcomes[0]
        #expect(outcome.assignedUUID == nil)
        #expect(outcome.mergedLoserUUIDs == [lowerBeta])
        #expect(outcome.errors.isEmpty)

        let saved = try #require(try await contacts.fetch(localID: "C1"))
        let gwURLs = guessWhoURLs(in: saved)
        // The winner URL was uppercase in the input; the loser must be removed.
        // We don't require the surviving URL to be re-cased — only that it parses
        // to the winning canonical UUID and is the only GuessWho URL left.
        #expect(gwURLs.count == 1)
        #expect(SidecarKey.parseGuessWhoContactURL(gwURLs[0]) == lowerAlpha)

        let winner = try #require(try sidecars.read(SidecarKey(kind: .contact, id: lowerAlpha)))
        #expect(Set(winner.fields.keys) == ["nickname", "notes"])

        #expect(try sidecars.read(SidecarKey(kind: .contact, id: lowerBeta)) == nil)
    }

    @Test
    func combined_deletedContactLeavesOrphanSidecarUntouched() async throws {
        let contacts = InMemoryContactStore()
        let sidecars = InMemorySidecarStore()
        let orphanKey = SidecarKey(kind: .contact, id: alpha)
        let orphan = SidecarEnvelope(entityID: alpha, fields: [
            "nickname": SidecarCell(value: .string("ghost"), modifiedAt: t1, modifiedBy: "device-Y"),
        ])
        try sidecars.write(orphan, at: orphanKey)

        let sync = makeSync(contacts: contacts, sidecars: sidecars)
        let report = try await sync.reconcileContactIdentities()

        #expect(report.contactOutcomes.isEmpty)
        #expect(report.orphanSidecars == [orphanKey])

        let after = try #require(try sidecars.read(orphanKey))
        #expect(after.entityID == alpha)
        #expect(after.fields.keys.contains("nickname"))
    }
}
