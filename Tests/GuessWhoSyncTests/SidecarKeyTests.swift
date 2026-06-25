import Foundation
import Testing
@testable import GuessWhoSync

@Suite("SidecarKey")
struct SidecarKeyTests {
    @Test
    func forContactReturnsKeyWhenGuessWhoURLPresent() {
        let uuid = "550E8400-E29B-41D4-A716-446655440000"
        let contact = Contact(
            localID: "local-1",
            urlAddresses: [
                LabeledValue(label: "home", value: "https://example.com"),
                LabeledValue(label: "GuessWho", value: "guesswho://contact/\(uuid)"),
            ]
        )
        let key = SidecarKey.forContact(contact)
        #expect(key == SidecarKey(kind: .contact, id: uuid))
    }

    @Test
    func forContactReturnsNilWhenNoURL() {
        let contact = Contact(localID: "local-1", urlAddresses: [])
        #expect(SidecarKey.forContact(contact) == nil)
    }

    @Test
    func forContactReturnsNilWhenOnlyMalformedUUID() {
        let contact = Contact(
            localID: "local-1",
            urlAddresses: [LabeledValue(label: "GuessWho", value: "guesswho://contact/notauuid")]
        )
        #expect(SidecarKey.forContact(contact) == nil)
    }

    @Test
    func forContactReturnsNilWhenEmptySuffix() {
        let contact = Contact(
            localID: "local-1",
            urlAddresses: [LabeledValue(label: "GuessWho", value: "guesswho://contact/")]
        )
        #expect(SidecarKey.forContact(contact) == nil)
    }

    @Test
    func forContactReturnsNilWhenWrongHost() {
        let contact = Contact(
            localID: "local-1",
            urlAddresses: [LabeledValue(label: "GuessWho", value: "guesswho://other/abc")]
        )
        #expect(SidecarKey.forContact(contact) == nil)
    }

    @Test
    func forContactSkipsMalformedAndReturnsValid() {
        let uuid = "550E8400-E29B-41D4-A716-446655440000"
        let contact = Contact(
            localID: "local-1",
            urlAddresses: [
                LabeledValue(label: "GuessWho", value: "guesswho://contact/notauuid"),
                LabeledValue(label: "GuessWho", value: "guesswho://contact/\(uuid)"),
            ]
        )
        #expect(SidecarKey.forContact(contact) == SidecarKey(kind: .contact, id: uuid))
    }

    @Test
    func forEventReturnsKeyFromEventUUID() {
        let uuid = UUID(uuidString: "550E8400-E29B-41D4-A716-446655440000")!
        let event = Event(
            id: uuid,
            eventKitID: nil,
            startDate: Date(timeIntervalSince1970: 0),
            endDate: Date(timeIntervalSince1970: 60)
        )
        // SidecarKey.init lowercases the event id (the new .event branch).
        #expect(SidecarKey.forEvent(event) == SidecarKey(kind: .event, id: uuid.uuidString))
        #expect(SidecarKey.forEvent(event).id == uuid.uuidString.lowercased())
    }

    @Test
    func sidecarKeyLowercasesEventIDs() {
        let upperUUID = "550E8400-E29B-41D4-A716-446655440000"
        let lowerUUID = upperUUID.lowercased()
        let key = SidecarKey(kind: .event, id: upperUUID)
        #expect(key.id == lowerUUID)
    }

    @Test
    func sidecarKeyEventIDsWithDifferentCasingAreEqual() {
        let upperUUID = "550E8400-E29B-41D4-A716-446655440000"
        let lowerUUID = upperUUID.lowercased()
        #expect(SidecarKey(kind: .event, id: upperUUID) == SidecarKey(kind: .event, id: lowerUUID))
    }

    // MARK: - matches(_ contactID:)

    /// A reconciled contact whose `ContactID.guessWhoID` is the given lowercased
    /// UUID.
    private func reconciledContactID(uuid: String) -> ContactID {
        ContactID(contact: Contact(
            localID: "local-1",
            urlAddresses: [LabeledValue(label: "GuessWho", value: "\(SidecarKey.guessWhoContactURLPrefix)\(uuid)")]
        ))
    }

    /// An un-reconciled contact (no GuessWho URL) — `guessWhoID` is nil.
    private func unreconciledContactID() -> ContactID {
        ContactID(contact: Contact(localID: "local-1", urlAddresses: []))
    }

    @Test
    func matchesTrueForContactEndpointWithSameGuessWhoID() {
        let uuid = "550e8400-e29b-41d4-a716-446655440000"
        let key = SidecarKey(kind: .contact, id: uuid)
        #expect(key.matches(reconciledContactID(uuid: uuid)))
    }

    @Test
    func matchesTrueAcrossCaseDifferences() {
        // The key lowercases at init; guessWhoID is canonical lowercase. A
        // mixed-case URL UUID still matches a mixed-case key id.
        let mixed = "550E8400-E29B-41D4-A716-446655440000"
        let key = SidecarKey(kind: .contact, id: mixed)
        #expect(key.matches(reconciledContactID(uuid: mixed)))
    }

    @Test
    func matchesFalseForDifferentUUID() {
        let key = SidecarKey(kind: .contact, id: "550e8400-e29b-41d4-a716-446655440000")
        #expect(!key.matches(reconciledContactID(uuid: "11111111-1111-1111-1111-111111111111")))
    }

    @Test
    func matchesFalseForUnreconciledContactID() {
        // guessWhoID nil ⇒ can't be a link endpoint ⇒ never matches.
        let key = SidecarKey(kind: .contact, id: "550e8400-e29b-41d4-a716-446655440000")
        #expect(!key.matches(unreconciledContactID()))
    }

    @Test
    func matchesFalseForEventKind() {
        // Same id string, wrong kind: an `.event` key never matches a contact.
        let uuid = "550e8400-e29b-41d4-a716-446655440000"
        let key = SidecarKey(kind: .event, id: uuid)
        #expect(!key.matches(reconciledContactID(uuid: uuid)))
    }

    @Test
    func matchesFalseForLinkKind() {
        let uuid = "550e8400-e29b-41d4-a716-446655440000"
        let key = SidecarKey(kind: .link, id: uuid)
        #expect(!key.matches(reconciledContactID(uuid: uuid)))
    }
}
