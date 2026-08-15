import Foundation
import Testing
@testable import GuessWhoSync
import GuessWhoSyncTesting

@Suite("GroupIdentity")
struct GroupIdentityTests {
    private func makeSync(
        deviceID: String = "device-A",
        store: InMemorySidecarStore = InMemorySidecarStore()
    ) -> GuessWhoSync {
        GuessWhoSync(
            contacts: InMemoryContactStore(),
            events: InMemoryEventStore(),
            sidecars: store,
            deviceID: deviceID
        )
    }

    // MARK: - Membership fingerprint

    @Test func fingerprintIsOrderIndependent() {
        let forward = GroupIdentity.fingerprint(forGuessWhoIDs: ["a", "b", "c"])
        let shuffled = GroupIdentity.fingerprint(forGuessWhoIDs: ["c", "a", "b"])
        #expect(forward.memberHash == shuffled.memberHash)
        #expect(forward.hashedMemberCount == 3)
        #expect(shuffled.hashedMemberCount == 3)
    }

    @Test func fingerprintLowercasesAndDeduplicates() {
        // "A" folds to "a"; the duplicate collapses so the hash is over {a}
        // and only one distinct id is counted.
        let mixed = GroupIdentity.fingerprint(forGuessWhoIDs: ["A", "a"])
        let single = GroupIdentity.fingerprint(forGuessWhoIDs: ["a"])
        #expect(mixed.memberHash == single.memberHash)
        #expect(mixed.hashedMemberCount == 1)
        #expect(single.hashedMemberCount == 1)
    }

    @Test func fingerprintFixedKnownDigest() {
        // Pins the exact framing (lowercase → dedup → sort → "\n"-join → SHA-256
        // hex). Independently computed: SHA-256(UTF8("a\nb")). A change to the
        // separator, casing, or sort order breaks this on purpose.
        let fp = GroupIdentity.fingerprint(forGuessWhoIDs: ["b", "a"])
        #expect(fp.memberHash == "7e18f737311b2dc3b2f269dd78396b0351f14fb66efa879f768cb23181883c78")
        #expect(fp.hashedMemberCount == 2)
    }

    @Test func fingerprintEmptyIsEmptyStringDigest() {
        // No reconciled members → the fold input is the empty string, whose
        // SHA-256 is the well-known e3b0c442… digest; nothing was folded.
        let fp = GroupIdentity.fingerprint(forGuessWhoIDs: [])
        #expect(fp.memberHash == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(fp.hashedMemberCount == 0)
    }

    // MARK: - Name normalization

    @Test func normalizedNameTrimsAndCaseFolds() {
        #expect(GroupIdentity.normalizedName("  Friends  ") == "friends")
        #expect(GroupIdentity.normalizedName("FRIENDS") == "friends")
        #expect(GroupIdentity.normalizedName("\nWork Buddies\t") == "work buddies")
    }

    @Test func normalizedNameComposesUnicodeCanonically() {
        // A decomposed "café" (e + U+0301 combining acute) must be folded to the
        // precomposed scalar U+00E9 in the STORED key, so the on-disk bytes are
        // deterministic across devices. (Swift String `==` is already canonical,
        // so we assert at the scalar level rather than via string equality.)
        let normalized = GroupIdentity.normalizedName("cafe\u{0301}")
        #expect(normalized.unicodeScalars.contains("\u{00E9}"))
        #expect(!normalized.unicodeScalars.contains("\u{0301}"))
        // And it still equals the precomposed spelling as a key.
        #expect(normalized == GroupIdentity.normalizedName("caf\u{00E9}"))
    }

    // MARK: - Model id canonicalization

    @Test func modelCanonicalizesIDToLowercase() {
        let upper = "3F2504E0-4F89-41D3-9A0C-0305E82C3301"
        let record = GroupIdentity(id: upper, name: "x", memberCount: 0, memberHash: "", hashedMemberCount: 0)
        #expect(record.id == upper.lowercased())
    }

    @Test func decodeCanonicalizesIDToLowercase() throws {
        let json = """
        {"id":"3F2504E0-4F89-41D3-9A0C-0305E82C3301","name":"x","account":"cardDAV:iCloud",\
        "memberCount":4,"memberHash":"deadbeef","hashedMemberCount":3,\
        "deviceLocalIDs":{"device-A":"local-1"}}
        """
        let record = try JSONDecoder().decode(GroupIdentity.self, from: Data(json.utf8))
        #expect(record.id == "3f2504e0-4f89-41d3-9a0c-0305e82c3301")
        #expect(record.name == "x")
        #expect(record.account == "cardDAV:iCloud")
        #expect(record.memberCount == 4)
        #expect(record.hashedMemberCount == 3)
        #expect(record.deviceLocalIDs["device-A"] == "local-1")
    }

    @Test func decodeDefaultsAdvisoryFieldsWhenAbsent() throws {
        // A minimally-populated peer record still decodes: only id + name are
        // required, the advisory scalars/collection default rather than throw.
        let json = #"{"id":"AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA","name":"y"}"#
        let record = try JSONDecoder().decode(GroupIdentity.self, from: Data(json.utf8))
        #expect(record.id == "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")
        #expect(record.name == "y")
        #expect(record.account == nil)
        #expect(record.memberCount == 0)
        #expect(record.memberHash == "")
        #expect(record.hashedMemberCount == 0)
        #expect(record.deviceLocalIDs.isEmpty)
    }

    // MARK: - Mint: unreconciled members counted, hash advisory

    @Test func mintRetainsTotalCountWhileHashCoversReconciledOnly() throws {
        let sync = makeSync()
        // Three members in the group, but only two carry a GuessWho ID yet.
        let fingerprint = GroupIdentity.fingerprint(forGuessWhoIDs: ["gw-1", "gw-2"])
        let minted = try sync.mintGroupIdentity(
            name: "Team",
            memberCount: 3,
            memberHash: fingerprint.memberHash,
            hashedMemberCount: fingerprint.hashedMemberCount,
            localID: "grp-local-A"
        )
        #expect(minted.memberCount == 3)          // un-reconciled member still counted
        #expect(minted.hashedMemberCount == 2)    // only reconciled members fed the hash
        #expect(minted.memberHash == fingerprint.memberHash)
        #expect(minted.name == "team")            // mint normalizes the name

        // Survives the round-trip through the sidecar unchanged.
        let read = try #require(try sync.groupIdentity(id: minted.id))
        #expect(read.memberCount == 3)
        #expect(read.hashedMemberCount == 2)
        #expect(read.memberHash == fingerprint.memberHash)
        #expect(read.deviceLocalIDs["device-A"] == "grp-local-A")
    }

    // MARK: - Sidecar round-trip + all listing

    @Test func sidecarRoundTripAndAllListing() throws {
        let sync = makeSync()
        let a = try sync.mintGroupIdentity(
            name: "Alpha", account: "cardDAV:iCloud",
            memberCount: 1, memberHash: "h-a", hashedMemberCount: 1, localID: "la"
        )
        let b = try sync.mintGroupIdentity(
            name: "Beta",
            memberCount: 2, memberHash: "h-b", hashedMemberCount: 2, localID: "lb"
        )

        let all = try sync.allGroupIdentities()
        #expect(all.count == 2)
        #expect(Set(all.map(\.id)) == Set([a.id, b.id]))

        let readA = try #require(try sync.groupIdentity(id: a.id))
        #expect(readA.name == "alpha")
        #expect(readA.account == "cardDAV:iCloud")
        #expect(readA.memberHash == "h-a")

        // Unknown id resolves to nil, not a wrong record.
        #expect(try sync.groupIdentity(id: UUID().uuidString) == nil)
    }

    @Test func groupIdentityLookupIsCaseInsensitiveOnID() throws {
        let sync = makeSync()
        let minted = try sync.mintGroupIdentity(
            name: "Case", memberCount: 0, memberHash: "", hashedMemberCount: 0, localID: "lc"
        )
        // The minted id is already lowercase; an upper-cased lookup must still
        // resolve, because SidecarKey canonicalizes the id.
        let read = try #require(try sync.groupIdentity(id: minted.id.uppercased()))
        #expect(read.id == minted.id)
    }

    // MARK: - Per-device slot semantics

    @Test func writeStampsAndUnionsSlotsAcrossDevices() throws {
        let store = InMemorySidecarStore()
        let syncA = makeSync(deviceID: "device-A", store: store)
        let syncB = makeSync(deviceID: "device-B", store: store)

        // Device A mints, seeding its own slot.
        let minted = try syncA.mintGroupIdentity(
            name: "Shared", memberCount: 0, memberHash: "h", hashedMemberCount: 0, localID: "localA"
        )
        #expect(minted.deviceLocalIDs == ["device-A": "localA"])

        // Device B pins its own slot on the SAME record. Its incoming record
        // carries only B's slot, yet A's slot must survive (union over on-disk).
        var forB = minted
        forB.deviceLocalIDs = ["device-B": "localB"]
        try syncB.writeGroupIdentity(forB)

        let afterB = try #require(try syncA.groupIdentity(id: minted.id))
        #expect(afterB.deviceLocalIDs["device-A"] == "localA")
        #expect(afterB.deviceLocalIDs["device-B"] == "localB")
    }

    @Test func writeIgnoresOtherDevicesSlotsInIncomingRecord() throws {
        // A device may only author its OWN slot. A record that tries to set a
        // peer's slot must not create/overwrite that peer's entry.
        let store = InMemorySidecarStore()
        let syncA = makeSync(deviceID: "device-A", store: store)

        let minted = try syncA.mintGroupIdentity(
            name: "Solo", memberCount: 0, memberHash: "h", hashedMemberCount: 0, localID: "localA"
        )
        var forged = minted
        forged.deviceLocalIDs = ["device-A": "localA", "device-B": "forged-by-A"]
        try syncA.writeGroupIdentity(forged)

        let read = try #require(try syncA.groupIdentity(id: minted.id))
        #expect(read.deviceLocalIDs["device-A"] == "localA")
        #expect(read.deviceLocalIDs["device-B"] == nil)   // A cannot mint B's slot
    }

    @Test func writePrunesOnlyOwnSlot() throws {
        let store = InMemorySidecarStore()
        let syncA = makeSync(deviceID: "device-A", store: store)
        let syncB = makeSync(deviceID: "device-B", store: store)

        let minted = try syncA.mintGroupIdentity(
            name: "Shared", memberCount: 0, memberHash: "h", hashedMemberCount: 0, localID: "localA"
        )
        var forB = minted
        forB.deviceLocalIDs = ["device-B": "localB"]
        try syncB.writeGroupIdentity(forB)

        // Device A prunes its own dangling handle by writing a record that omits
        // its slot. B's slot must remain untouched.
        var pruneA = try #require(try syncA.groupIdentity(id: minted.id))
        pruneA.deviceLocalIDs.removeValue(forKey: "device-A")
        try syncA.writeGroupIdentity(pruneA)

        let afterPrune = try #require(try syncA.groupIdentity(id: minted.id))
        #expect(afterPrune.deviceLocalIDs["device-A"] == nil)      // pruned own slot
        #expect(afterPrune.deviceLocalIDs["device-B"] == "localB") // peer slot survives
    }

    @Test func writeAppliesScalarLastWriterWins() throws {
        let sync = makeSync()
        let minted = try sync.mintGroupIdentity(
            name: "Rename Me", memberCount: 1, memberHash: "old", hashedMemberCount: 1, localID: "la"
        )
        var updated = minted
        updated.name = GroupIdentity.normalizedName("Renamed")
        updated.memberCount = 5
        updated.memberHash = "new"
        updated.hashedMemberCount = 4
        try sync.writeGroupIdentity(updated)

        let read = try #require(try sync.groupIdentity(id: minted.id))
        #expect(read.name == "renamed")
        #expect(read.memberCount == 5)
        #expect(read.memberHash == "new")
        #expect(read.hashedMemberCount == 4)
        #expect(read.deviceLocalIDs["device-A"] == "la")   // slot preserved across a scalar update
    }
}
