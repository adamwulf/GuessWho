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
}
