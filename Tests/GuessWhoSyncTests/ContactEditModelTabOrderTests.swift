import Foundation
import Testing
@testable import GuessWhoSync

@Suite("ContactEditModel tab order")
struct ContactEditModelTabOrderTests {

    private static let nameAndOrganization: [ContactEditModel.Field] = [
        .namePrefix, .givenName, .middleName, .familyName, .nameSuffix, .nickname,
        .organizationName, .departmentName, .jobTitle,
    ]

    @Test("A blank contact tabs through the names, the organization fields, then Notes")
    func blankContactOrder() {
        let model = ContactEditModel(newContactSeed: Contact())
        #expect(model.tabOrder(includingPhoneticName: false) == Self.nameAndOrganization + [.note])
    }

    @Test("Every entry of every multi-value row is a stop, in row order")
    func multiValueRowsInRowOrder() {
        let contact = Contact(
            phoneNumbers: [
                LabeledValue(label: "mobile", value: "1"),
                LabeledValue(label: "home", value: "2"),
            ],
            emailAddresses: [LabeledValue(label: "home", value: "a@example.com")],
            postalAddresses: [LabeledPostalAddress(label: "home", value: PostalAddress())],
            urlAddresses: [LabeledValue(label: "home", value: "https://example.com")],
            socialProfiles: [
                LabeledSocialProfile(
                    label: "",
                    value: SocialProfile(urlString: "", username: "a", userIdentifier: "", service: "Twitter")
                )
            ],
            instantMessageAddresses: [
                LabeledInstantMessageAddress(
                    label: "",
                    value: InstantMessageAddress(username: "a", service: "Skype")
                )
            ],
            contactRelations: [LabeledContactRelation(label: "friend", value: ContactRelation(name: "B"))]
        )
        let model = ContactEditModel(original: contact)

        let expected: [ContactEditModel.Field] = Self.nameAndOrganization + [
            .phone(0), .phone(1),
            .email(0),
            .url(0),
            .street(0), .city(0), .state(0), .postalCode(0), .country(0),
            .relation(0),
            .socialProfile(0),
            .instantMessage(0),
            .note,
        ]
        #expect(model.tabOrder(includingPhoneticName: false) == expected)
    }

    @Test("A label shown as a text field is a stop just before its entry's value field")
    func labelFieldsPrecedeTheirValue() {
        let contact = Contact(
            phoneNumbers: [
                LabeledValue(label: "mobile", value: "1"),
                LabeledValue(label: "custom", value: "2"),
            ],
            emailAddresses: [LabeledValue(label: "custom", value: "a@example.com")],
            postalAddresses: [LabeledPostalAddress(label: "custom", value: PostalAddress())],
            urlAddresses: [LabeledValue(label: "custom", value: "https://example.com")],
            dates: [LabeledDate(label: "custom", value: DateComponents(month: 1, day: 2))],
            socialProfiles: [
                LabeledSocialProfile(
                    label: "custom",
                    value: SocialProfile(urlString: "", username: "a", userIdentifier: "", service: "Twitter")
                )
            ],
            instantMessageAddresses: [
                LabeledInstantMessageAddress(
                    label: "custom",
                    value: InstantMessageAddress(username: "a", service: "Skype")
                )
            ],
            contactRelations: [LabeledContactRelation(label: "custom", value: ContactRelation(name: "B"))]
        )
        let model = ContactEditModel(original: contact)
        var asked: [ContactEditModel.Field] = []
        let order = model.tabOrder(includingPhoneticName: false) { labelField, label in
            asked.append(labelField)
            return label == "custom"
        }

        // Every labeled entry is asked about. Social and IM are not, even
        // with a "custom" label: their picker sets the service, and it has
        // no label text field.
        #expect(asked == [
            .phoneLabel(0), .phoneLabel(1), .emailLabel(0), .urlLabel(0),
            .addressLabel(0), .dateLabel(0), .relationLabel(0),
        ])
        #expect(order == Self.nameAndOrganization + [
            .phone(0), .phoneLabel(1), .phone(1),
            .emailLabel(0), .email(0),
            .urlLabel(0), .url(0),
            .addressLabel(0), .street(0), .city(0), .state(0), .postalCode(0), .country(0),
            // A date's only stop is its label field.
            .dateLabel(0),
            .relationLabel(0), .relation(0),
            .socialProfile(0),
            .instantMessage(0),
            .note,
        ])
    }

    @Test("Shift-Tab from a value field goes to its label field when that is shown")
    func shiftTabReachesTheLabelField() {
        let contact = Contact(phoneNumbers: [LabeledValue(label: "custom", value: "1")])
        let order = ContactEditModel(original: contact).tabOrder(includingPhoneticName: false) { _, label in
            label == "custom"
        }
        #expect(ContactEditModel.tabStop(from: .phone(0), backward: true, in: order) == .phoneLabel(0))
        #expect(ContactEditModel.tabStop(from: .phoneLabel(0), backward: false, in: order) == .phone(0))
        #expect(ContactEditModel.tabStop(from: .phoneLabel(0), backward: true, in: order) == .jobTitle)
    }

    @Test("The hidden guesswho:// URL is not a stop: only the URLs the editor shows are")
    func hiddenURLIsNotAStop() {
        let contact = Contact(urlAddresses: [
            LabeledValue(label: "GuessWho", value: "guesswho://contact/550e8400-e29b-41d4-a716-446655440000"),
            LabeledValue(label: "home", value: "https://example.com"),
        ])
        let model = ContactEditModel(original: contact)
        let urls = model.tabOrder(includingPhoneticName: false).filter {
            if case .url = $0 { return true }
            return false
        }
        #expect(urls == [.url(0)])
    }

    @Test("The phonetic fields are stops only while their group is open, just before Notes")
    func phoneticNameOnlyWhenOpen() {
        let model = ContactEditModel(newContactSeed: Contact())
        #expect(model.tabOrder(includingPhoneticName: true) == Self.nameAndOrganization + [
            .phoneticGivenName, .phoneticMiddleName, .phoneticFamilyName, .note,
        ])
        #expect(!model.tabOrder(includingPhoneticName: false).contains(.phoneticGivenName))
    }

    @Test("Tab moves to the next field and Shift-Tab to the previous one")
    func tabAndShiftTabStep() {
        let order = ContactEditModel(newContactSeed: Contact()).tabOrder(includingPhoneticName: false)
        #expect(ContactEditModel.tabStop(from: .givenName, backward: false, in: order) == .middleName)
        #expect(ContactEditModel.tabStop(from: .givenName, backward: true, in: order) == .namePrefix)
        #expect(ContactEditModel.tabStop(from: .nickname, backward: false, in: order) == .organizationName)
    }

    @Test("Tab wraps at both ends, so it never leaves the editor")
    func wrapsAtBothEnds() {
        let order = ContactEditModel(newContactSeed: Contact()).tabOrder(includingPhoneticName: false)
        #expect(ContactEditModel.tabStop(from: .note, backward: false, in: order) == .namePrefix)
        #expect(ContactEditModel.tabStop(from: .namePrefix, backward: true, in: order) == .note)
    }

    @Test("A field that is not in the order goes to the first field, or the last going backward")
    func unknownFieldGoesToAnEnd() {
        let order = ContactEditModel(newContactSeed: Contact()).tabOrder(includingPhoneticName: false)
        // No phone numbers, so `.phone(0)` has no row.
        #expect(ContactEditModel.tabStop(from: .phone(0), backward: false, in: order) == .namePrefix)
        #expect(ContactEditModel.tabStop(from: .phone(0), backward: true, in: order) == .note)
        #expect(ContactEditModel.tabStop(from: nil, backward: false, in: order) == .namePrefix)
        // A collapsed phonetic group: its fields are not in the order.
        #expect(ContactEditModel.tabStop(from: .phoneticFamilyName, backward: false, in: order) == .namePrefix)
    }

    @Test("An empty order has no stop")
    func emptyOrderHasNoStop() {
        #expect(ContactEditModel.tabStop(from: .givenName, backward: false, in: []) == nil)
        #expect(ContactEditModel.tabStop(from: nil, backward: true, in: []) == nil)
    }
}
