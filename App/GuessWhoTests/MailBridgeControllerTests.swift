#if targetEnvironment(macCatalyst)

import Foundation
import Testing
import GuessWhoSync
@testable import GuessWho

@Suite("Mail contact snapshot projection")
struct MailBridgeControllerTests {
    @Test
    func projectionCarriesComposeDetailsAndHighlightReasons() throws {
        let contact = Contact(
            givenName: "Ada",
            familyName: "Lovelace",
            jobTitle: "Mathematician",
            organizationName: "Analytical Engines",
            emailAddresses: [LabeledValue(label: "work", value: " ADA@Example.COM ")]
        )
        let thumbnail = Data([0x01, 0x02, 0x03])
        let snapshot = MailContactSnapshotBuilder.build([
            MailSnapshotContact(
                contact: contact,
                thumbnail: thumbnail,
                highlightReasons: [.favoriteContact, .favoriteGroupMember]
            )
        ], generatedAt: Date(timeIntervalSince1970: 1_000))

        let summary = try #require(snapshot.summaries(forAddress: "ada@example.com").first)
        #expect(summary.displayName == "Ada Lovelace")
        #expect(summary.organization == "Analytical Engines")
        #expect(summary.jobTitle == "Mathematician")
        #expect(summary.thumbnail == thumbnail)
        #expect(summary.highlightReasons == [.favoriteContact, .favoriteGroupMember])
    }

    @Test
    func sharedAddressKeepsEveryMatchingContact() {
        let first = Contact(
            givenName: "First",
            emailAddresses: [LabeledValue(label: "home", value: "shared@example.com")]
        )
        let second = Contact(
            givenName: "Second",
            emailAddresses: [LabeledValue(label: "work", value: "SHARED@example.com")]
        )
        let snapshot = MailContactSnapshotBuilder.build([
            MailSnapshotContact(
                contact: second,
                thumbnail: nil,
                highlightReasons: [.favoriteOrganizationMember]
            ),
            MailSnapshotContact(
                contact: first,
                thumbnail: nil,
                highlightReasons: []
            ),
        ], generatedAt: .distantPast)

        let summaries = snapshot.summaries(forAddress: "shared@example.com")
        #expect(summaries.map(\.displayName) == ["First", "Second"])
        #expect(summaries[0].isHighlighted == false)
        #expect(summaries[1].highlightReasons == [.favoriteOrganizationMember])
    }

    @Test
    func projectionIsStableAndSkipsContactsWithoutEmail() {
        let alpha = Contact(
            givenName: "Alpha",
            emailAddresses: [LabeledValue(label: "home", value: "alpha@example.com")]
        )
        let beta = Contact(
            givenName: "Beta",
            emailAddresses: [LabeledValue(label: "home", value: "beta@example.com")]
        )
        let noEmail = Contact(givenName: "No Email")
        let inputs = [
            MailSnapshotContact(contact: beta, thumbnail: nil, highlightReasons: []),
            MailSnapshotContact(contact: noEmail, thumbnail: nil, highlightReasons: [.favoriteContact]),
            MailSnapshotContact(contact: alpha, thumbnail: nil, highlightReasons: []),
        ]

        let forward = MailContactSnapshotBuilder.build(inputs, generatedAt: .distantPast)
        let reverse = MailContactSnapshotBuilder.build(Array(inputs.reversed()), generatedAt: .distantPast)
        #expect(forward == reverse)
        #expect(forward.summaries(forAddress: "alpha@example.com").count == 1)
        #expect(forward.summaries(forAddress: "beta@example.com").count == 1)
    }

    @Test
    func addressIndexUsesTheMailCacheNormalizer() {
        let contact = Contact(
            givenName: "Ada",
            emailAddresses: [
                LabeledValue(label: "work", value: "Ada Lovelace <ADA@Example.COM.>")
            ],
            urlAddresses: [
                LabeledValue(
                    label: "GuessWho",
                    value: "guesswho://contact/00000000-0000-0000-0000-000000000001"
                )
            ]
        )
        let index = MailContactAddressIndex(contacts: [contact])

        #expect(index.contactIDs(matching: "mailto:ada@example.com?subject=Hello") == [contact.contactID])
    }

    @Test
    func projectionBoundsThumbnailBytesDeterministically() {
        let thumbnail = Data(repeating: 0x5a, count: MailContactSnapshotBuilder.maximumThumbnailByteCount)
        let contacts = (0..<40).map { index in
            MailSnapshotContact(
                contact: Contact(
                    givenName: "Person \(index)",
                    emailAddresses: [
                        LabeledValue(label: "work", value: "person\(index)@example.com")
                    ]
                ),
                thumbnail: thumbnail,
                highlightReasons: []
            )
        }

        let forward = MailContactSnapshotBuilder.build(contacts, generatedAt: .distantPast)
        let reverse = MailContactSnapshotBuilder.build(Array(contacts.reversed()), generatedAt: .distantPast)
        #expect(forward == reverse)
        let kept = (0..<40).filter { index in
            forward.summaries(forAddress: "person\(index)@example.com").first?.thumbnail != nil
        }
        #expect(kept.count == 32)
    }

    @Test
    func publicationDoesNotRewriteAnEquivalentSnapshot() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("contacts.plist")
        let store = MailContactCacheStore(fileURL: url)
        var stored = MailContactSnapshot(generatedAt: Date(timeIntervalSince1970: 100))
        stored.add(MailContactSummary(displayName: "Ada"), forAddresses: ["ada@example.com"])
        try store.write(stored)
        let before = try Data(contentsOf: url)

        var candidate = stored
        candidate.generatedAt = Date(timeIntervalSince1970: 200)
        let outcome = await MailContactCachePublication.publish(candidate, to: store)

        #expect(outcome == .unchanged)
        #expect(try Data(contentsOf: url) == before)
    }

    @Test
    func publicationPreservesAnUnreadableNewerCache() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("contacts.plist")
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["version": 999, "futureIndex": ["opaque": true]],
            format: .binary,
            options: 0
        )
        try data.write(to: url)
        let store = MailContactCacheStore(fileURL: url)

        let outcome = await MailContactCachePublication.publish(
            MailContactSnapshot(generatedAt: .distantPast),
            to: store
        )

        #expect(outcome == .preservedNewer(version: 999))
        #expect(try Data(contentsOf: url) == data)
    }
}

#endif
