import Testing
@testable import GuessWhoSync

@Suite("LabeledValue")
struct LabeledValueTests {
    @Test
    func initStoresFields() {
        let value = LabeledValue(label: "GuessWho", value: "guesswho://contact/abc")
        #expect(value.label == "GuessWho")
        #expect(value.value == "guesswho://contact/abc")
    }

    @Test
    func equalityAndHashing() {
        let a = LabeledValue(label: "home", value: "https://example.com")
        let b = LabeledValue(label: "home", value: "https://example.com")
        let c = LabeledValue(label: "work", value: "https://example.com")
        #expect(a == b)
        #expect(a != c)
        #expect(a.hashValue == b.hashValue)
    }
}
