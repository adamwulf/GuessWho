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
}

#endif
