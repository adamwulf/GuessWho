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
    func caseA_assignsFreshUUID() throws {
        let contact = Contact(localID: "C1", givenName: "Ada")
        let contacts = InMemoryContactStore(contacts: [contact])
        let sidecars = InMemorySidecarStore()
        let sync = makeSync(contacts: contacts, sidecars: sidecars)

        let report = try sync.reconcileContactIdentities()

        #expect(report.contactOutcomes.count == 1)
        let outcome = report.contactOutcomes[0]
        #expect(outcome.localID == "C1")
        #expect(outcome.assignedUUID != nil)
        #expect(outcome.removedMalformedURLs.isEmpty)
        #expect(outcome.mergedLoserUUIDs.isEmpty)
        #expect(outcome.errors.isEmpty)

        let saved = try #require(try contacts.fetch(localID: "C1"))
        let gwURLs = guessWhoURLs(in: saved)
        #expect(gwURLs.count == 1)
        let uuid = try #require(SidecarKey.parseGuessWhoContactURL(gwURLs[0]))
        #expect(uuid == outcome.assignedUUID)
        #expect(uuid == uuid.lowercased())

        let gwLabeled = saved.urlAddresses.first { $0.value.hasPrefix("guesswho://contact/") }
        #expect(gwLabeled?.label == "GuessWho")
    }

    @Test
    func caseA_withMalformedURLsThatNameExistingSidecars() throws {
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
                "nickname": .value(.string("ghost"), modifiedAt: t1, modifiedBy: "device-X"),
            ]),
            at: garbageKey
        )

        let sync = makeSync(contacts: contacts, sidecars: sidecars)
        let report = try sync.reconcileContactIdentities()

        let outcome = report.contactOutcomes[0]
        #expect(outcome.assignedUUID != nil)
        #expect(outcome.removedMalformedURLs == ["guesswho://contact/garbage"])

        let saved = try #require(try contacts.fetch(localID: "C1"))
        let gwURLs = guessWhoURLs(in: saved)
        #expect(gwURLs.count == 1)
        #expect(!gwURLs.contains("guesswho://contact/garbage"))

        #expect(try sidecars.read(garbageKey) != nil)
        #expect(report.orphanSidecars.contains(garbageKey))
    }

    @Test
    func caseB_singleValidIsNoOp() throws {
        let url = LabeledValue(label: "GuessWho", value: "guesswho://contact/" + alpha)
        let original = Contact(localID: "C1", givenName: "Ada", urlAddresses: [url])
        let contacts = InMemoryContactStore(contacts: [original])
        let sidecars = InMemorySidecarStore()
        let sync = makeSync(contacts: contacts, sidecars: sidecars)

        let report = try sync.reconcileContactIdentities()

        let outcome = report.contactOutcomes[0]
        #expect(outcome.assignedUUID == nil)
        #expect(outcome.mergedLoserUUIDs.isEmpty)
        #expect(outcome.removedMalformedURLs.isEmpty)
        #expect(outcome.errors.isEmpty)

        let saved = try #require(try contacts.fetch(localID: "C1"))
        #expect(saved == original)
    }

    @Test
    func caseC_validKeptAndMalformedRemoved() throws {
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

        let report = try sync.reconcileContactIdentities()

        let outcome = report.contactOutcomes[0]
        #expect(outcome.assignedUUID == nil)
        #expect(outcome.mergedLoserUUIDs.isEmpty)
        #expect(outcome.removedMalformedURLs == ["guesswho://contact/garbage"])

        let saved = try #require(try contacts.fetch(localID: "C1"))
        let gwURLs = guessWhoURLs(in: saved)
        #expect(gwURLs == ["guesswho://contact/" + alpha])
        #expect(saved.urlAddresses.contains(LabeledValue(label: "home", value: "https://example.com")))
    }

    @Test
    func caseD_twoValidLexSmallestWinsAndLoserSidecarMerged() throws {
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
                "nickname": .value(.string("Bear"), modifiedAt: t1, modifiedBy: "device-A"),
            ]),
            at: SidecarKey(kind: .contact, id: alpha)
        )
        try sidecars.write(
            SidecarEnvelope(entityID: beta, fields: [
                "notes": .value(.string("met"), modifiedAt: t1, modifiedBy: "device-B"),
            ]),
            at: SidecarKey(kind: .contact, id: beta)
        )

        let sync = makeSync(contacts: contacts, sidecars: sidecars)
        let report = try sync.reconcileContactIdentities()

        let outcome = report.contactOutcomes[0]
        #expect(outcome.assignedUUID == nil)
        #expect(outcome.mergedLoserUUIDs == [beta])
        #expect(outcome.errors.isEmpty)

        let saved = try #require(try contacts.fetch(localID: "C1"))
        let gwURLs = guessWhoURLs(in: saved)
        #expect(gwURLs == ["guesswho://contact/" + alpha])

        let winner = try #require(try sidecars.read(SidecarKey(kind: .contact, id: alpha)))
        #expect(winner.entityID == alpha)
        #expect(Set(winner.fields.keys) == ["nickname", "notes"])

        #expect(try sidecars.read(SidecarKey(kind: .contact, id: beta)) == nil)
    }

    @Test
    func caseD_perFieldLWWAcrossOverlappingAndDisjointFields() throws {
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
                "nickname": .value(.string("Bear"), modifiedAt: t1, modifiedBy: "device-A"),
                "color": .value(.string("blue"), modifiedAt: t2, modifiedBy: "device-A"),
            ]),
            at: SidecarKey(kind: .contact, id: alpha)
        )
        try sidecars.write(
            SidecarEnvelope(entityID: beta, fields: [
                "nickname": .value(.string("Bear-cub"), modifiedAt: t2, modifiedBy: "device-B"),
                "notes": .value(.string("met"), modifiedAt: t1, modifiedBy: "device-B"),
            ]),
            at: SidecarKey(kind: .contact, id: beta)
        )

        let sync = makeSync(contacts: contacts, sidecars: sidecars)
        _ = try sync.reconcileContactIdentities()

        let winner = try #require(try sidecars.read(SidecarKey(kind: .contact, id: alpha)))
        #expect(Set(winner.fields.keys) == ["nickname", "color", "notes"])

        guard case .value(let nick, let nickAt, let nickBy) = winner.fields["nickname"] else {
            Issue.record("nickname missing or wrong kind")
            return
        }
        #expect(nick == .string("Bear-cub"))
        #expect(nickAt == t2)
        #expect(nickBy == "device-B")

        guard case .value(let color, _, _) = winner.fields["color"] else {
            Issue.record("color missing")
            return
        }
        #expect(color == .string("blue"))

        guard case .value(let notes, _, _) = winner.fields["notes"] else {
            Issue.record("notes missing")
            return
        }
        #expect(notes == .string("met"))

        #expect(try sidecars.read(SidecarKey(kind: .contact, id: beta)) == nil)
    }

    @Test
    func caseD_threeValidLexSmallestWinsAndBothLosersMerged() throws {
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
                "fieldA": .value(.string("a"), modifiedAt: t1, modifiedBy: "device-A"),
            ]),
            at: SidecarKey(kind: .contact, id: alpha)
        )
        try sidecars.write(
            SidecarEnvelope(entityID: beta, fields: [
                "fieldB": .value(.string("b"), modifiedAt: t1, modifiedBy: "device-B"),
            ]),
            at: SidecarKey(kind: .contact, id: beta)
        )
        try sidecars.write(
            SidecarEnvelope(entityID: gamma, fields: [
                "fieldC": .value(.string("c"), modifiedAt: t1, modifiedBy: "device-C"),
            ]),
            at: SidecarKey(kind: .contact, id: gamma)
        )

        let sync = makeSync(contacts: contacts, sidecars: sidecars)
        let report = try sync.reconcileContactIdentities()

        let outcome = report.contactOutcomes[0]
        #expect(outcome.mergedLoserUUIDs == [beta, gamma])

        let saved = try #require(try contacts.fetch(localID: "C1"))
        #expect(guessWhoURLs(in: saved) == ["guesswho://contact/" + alpha])

        let winner = try #require(try sidecars.read(SidecarKey(kind: .contact, id: alpha)))
        #expect(Set(winner.fields.keys) == ["fieldA", "fieldB", "fieldC"])
        #expect(try sidecars.read(SidecarKey(kind: .contact, id: beta)) == nil)
        #expect(try sidecars.read(SidecarKey(kind: .contact, id: gamma)) == nil)
    }

    @Test
    func idempotentOnStableContact() throws {
        let url = LabeledValue(label: "GuessWho", value: "guesswho://contact/" + alpha)
        let contact = Contact(localID: "C1", givenName: "Ada", urlAddresses: [url])
        let contacts = InMemoryContactStore(contacts: [contact])
        let sidecars = InMemorySidecarStore()
        let sync = makeSync(contacts: contacts, sidecars: sidecars)

        _ = try sync.reconcileContactIdentities()
        let snapshot = try #require(try contacts.fetch(localID: "C1"))

        let report = try sync.reconcileContactIdentities()
        let outcome = report.contactOutcomes[0]
        #expect(outcome.assignedUUID == nil)
        #expect(outcome.mergedLoserUUIDs.isEmpty)
        #expect(outcome.errors.isEmpty)

        let after = try #require(try contacts.fetch(localID: "C1"))
        #expect(after == snapshot)
    }

    // MARK: - §9.6

    @Test
    func combined_twoDevicesIndependentUUIDsConverge() throws {
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
                "nickname": .value(.string("from-A"), modifiedAt: t1, modifiedBy: "device-A"),
                "shared": .value(.string("A-version"), modifiedAt: t1, modifiedBy: "device-A"),
            ]),
            at: SidecarKey(kind: .contact, id: alpha)
        )
        try sidecars.write(
            SidecarEnvelope(entityID: beta, fields: [
                "notes": .value(.string("from-B"), modifiedAt: t2, modifiedBy: "device-B"),
                "shared": .value(.string("B-version"), modifiedAt: t3, modifiedBy: "device-B"),
            ]),
            at: SidecarKey(kind: .contact, id: beta)
        )

        let sync = makeSync(contacts: contacts, sidecars: sidecars)
        _ = try sync.reconcileContactIdentities()

        let saved = try #require(try contacts.fetch(localID: "C1"))
        #expect(guessWhoURLs(in: saved) == ["guesswho://contact/" + alpha])

        let winner = try #require(try sidecars.read(SidecarKey(kind: .contact, id: alpha)))
        #expect(Set(winner.fields.keys) == ["nickname", "notes", "shared"])

        guard case .value(let shared, let sharedAt, let sharedBy) = winner.fields["shared"] else {
            Issue.record("shared missing")
            return
        }
        #expect(shared == .string("B-version"))
        #expect(sharedAt == t3)
        #expect(sharedBy == "device-B")

        #expect(try sidecars.read(SidecarKey(kind: .contact, id: beta)) == nil)
    }

    @Test
    func combined_deletedContactLeavesOrphanSidecarUntouched() throws {
        let contacts = InMemoryContactStore()
        let sidecars = InMemorySidecarStore()
        let orphanKey = SidecarKey(kind: .contact, id: alpha)
        let orphan = SidecarEnvelope(entityID: alpha, fields: [
            "nickname": .value(.string("ghost"), modifiedAt: t1, modifiedBy: "device-Y"),
        ])
        try sidecars.write(orphan, at: orphanKey)

        let sync = makeSync(contacts: contacts, sidecars: sidecars)
        let report = try sync.reconcileContactIdentities()

        #expect(report.contactOutcomes.isEmpty)
        #expect(report.orphanSidecars == [orphanKey])

        let after = try #require(try sidecars.read(orphanKey))
        #expect(after.entityID == alpha)
        #expect(after.fields.keys.contains("nickname"))
    }
}
