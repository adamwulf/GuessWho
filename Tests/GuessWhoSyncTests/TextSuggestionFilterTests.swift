import Foundation
import Testing
@testable import GuessWhoSync

/// The pure matching rules behind every autocompleting text field. See
/// `TextSuggestionFilter`.
@Suite("Text suggestion filter")
struct TextSuggestionFilterTests {
    private let companies = ["Acme", "Acme Labs", "Bletchley Park", "Zeta Corp", "Pacme Holdings"]

    @Test
    func blankQueryYieldsNothing() {
        #expect(TextSuggestionFilter.suggestions(matching: "", in: companies).isEmpty)
        #expect(TextSuggestionFilter.suggestions(matching: "   ", in: companies).isEmpty)
    }

    @Test
    func prefixMatchesRankBeforeWordPrefixBeforeSubstring() {
        let names = ["Wulfgang Amadeus", "Adam Wulf", "Beowulf Grendel", "Unrelated"]
        // "wulf" starts "Wulfgang…" (prefix), starts the second word of "Adam
        // Wulf" (word prefix), and merely appears inside "Beowulf" (substring).
        #expect(
            TextSuggestionFilter.suggestions(matching: "wulf", in: names)
                == ["Wulfgang Amadeus", "Adam Wulf", "Beowulf Grendel"]
        )
    }

    @Test
    func withinATierIncomingOrderIsKept() {
        // "Acme" and "Acme Labs" are both prefix matches and keep the caller's
        // order; "Pacme Holdings" is only a substring match, so it trails.
        #expect(TextSuggestionFilter.suggestions(matching: "ac", in: companies) == ["Acme", "Acme Labs", "Pacme Holdings"])
    }

    @Test
    func matchingIsCaseAndDiacriticInsensitive() {
        let names = ["Zoë Café", "Zoe Cafe Annex", "Élan"]
        #expect(TextSuggestionFilter.suggestions(matching: "ZOE CA", in: names) == ["Zoë Café", "Zoe Cafe Annex"])
        #expect(TextSuggestionFilter.suggestions(matching: "el", in: names) == ["Élan"])
    }

    @Test
    func anExactMatchIsNeverSuggestedBack() {
        // The user already typed "Acme"; only the longer names are useful.
        #expect(TextSuggestionFilter.suggestions(matching: "Acme", in: companies) == ["Acme Labs", "Pacme Holdings"])
        // Case, surrounding whitespace, and diacritics don't rescue it.
        #expect(TextSuggestionFilter.suggestions(matching: "  acme ", in: ["Acme"]).isEmpty)
    }

    @Test
    func blankAndDuplicateCandidatesCollapse() {
        let candidates = ["", "  ", "Acme", "acme", "ACME  ", "Acme Labs"]
        // First spelling wins; blanks vanish.
        #expect(TextSuggestionFilter.suggestions(matching: "a", in: candidates) == ["Acme", "Acme Labs"])
    }

    @Test
    func resultsAreCappedAtTheLimit() {
        let many = (1...20).map { "Candidate \($0)" }
        #expect(TextSuggestionFilter.suggestions(matching: "cand", in: many).count == TextSuggestionFilter.defaultLimit)
        #expect(TextSuggestionFilter.suggestions(matching: "cand", in: many, limit: 3) == ["Candidate 1", "Candidate 2", "Candidate 3"])
        #expect(TextSuggestionFilter.suggestions(matching: "cand", in: many, limit: 0).isEmpty)
    }

    @Test
    func multiWordQueriesMatchAcrossWordBoundaries() {
        let names = ["Adam Wulf", "Adam Wulfson", "Adamant Wulf"]
        #expect(TextSuggestionFilter.suggestions(matching: "adam w", in: names) == ["Adam Wulf", "Adam Wulfson"])
        // Extra internal whitespace in the query collapses like the candidates' does.
        #expect(TextSuggestionFilter.suggestions(matching: "adam   wulf", in: names) == ["Adam Wulfson"])
    }

    @Test
    func candidatesAreTrimmedInTheOutput() {
        #expect(TextSuggestionFilter.suggestions(matching: "b", in: ["  Bletchley Park \n"]) == ["Bletchley Park"])
    }

    @Test
    func noMatchYieldsNothing() {
        #expect(TextSuggestionFilter.suggestions(matching: "xyz", in: companies).isEmpty)
    }
}
