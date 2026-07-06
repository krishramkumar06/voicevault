import Testing
@testable import VoiceVaultCore

@Suite("Name correction")
struct NameCorrectorTests {
    let people = [
        PersonName(name: "Suren"),
        PersonName(name: "Isa", aliases: ["Issa"]),
        PersonName(name: "Sosnovsky"),
    ]

    // The three acceptance cases from the brief.

    @Test func sorenBecomesSuren() {
        let result = NameCorrector(people: people)
            .correct("I was talking to Soren about the project.")
        #expect(result.text == "I was talking to Suren about the project.")
        #expect(result.corrections == [NameCorrection(from: "Soren", to: "Suren")])
    }

    @Test func issaBecomesIsa() {
        let result = NameCorrector(people: people).correct("I miss Issa. Issa would love this.")
        #expect(result.text == "I miss Isa. Isa would love this.")
        #expect(result.corrections.first?.count == 2)
    }

    @Test func sasnowskiBecomesSosnovsky() {
        let result = NameCorrector(people: people)
            .correct("Then Sasnowski showed up late as usual.")
        #expect(result.text == "Then Sosnovsky showed up late as usual.")
    }

    // Guards: a verbatim transcript must never be corrupted.

    @Test func isAIsNeverCorrected() {
        let text = "This is a test and it is a good one."
        let result = NameCorrector(people: people).correct(text)
        #expect(result.text == text)
        #expect(result.corrections.isEmpty)
    }

    @Test func commonWordsAreNeverFuzzyMatched() {
        // "sure" is phonetically close-ish to "Suren" but is an everyday word.
        let text = "Sure, that sounds good."
        let result = NameCorrector(people: people).correct(text)
        #expect(result.text == text)
    }

    @Test func unrelatedNamesAreLeftAlone() {
        let text = "Lisa and Sarah were there with Sirens playing."
        let result = NameCorrector(people: people).correct(text)
        #expect(result.text == text)
    }

    @Test func canonicalSpellingIsNotFlaggedAsCorrection() {
        let result = NameCorrector(people: people).correct("Suren already spelled right.")
        #expect(result.corrections.isEmpty)
    }

    @Test func possessivesAreCorrected() {
        let result = NameCorrector(people: people).correct("That was Soren's idea.")
        #expect(result.text == "That was Suren's idea.")
    }

    @Test func aliasBeatsCommonWordGuard() {
        // If the user explicitly maps a common word as an alias, believe them.
        let will = [PersonName(name: "Will Chen", aliases: ["will chen"])]
        let result = NameCorrector(people: will).correct("I saw will chen at lunch.")
        #expect(result.text == "I saw Will Chen at lunch.")
    }

    @Test func multiWordNamesMatchFuzzily() {
        let people = [PersonName(name: "Isabel Matos")]
        let result = NameCorrector(people: people).correct("I told Isabelle Mattos about it.")
        #expect(result.text == "I told Isabel Matos about it.")
    }

    @Test func emptyPeopleListChangesNothing() {
        let text = "Soren and Issa walked in."
        let result = NameCorrector(people: []).correct(text)
        #expect(result.text == text)
    }

    // Phonetic internals, pinned so refactors can't silently regress.

    @Test func metaphoneKeys() {
        #expect(NameCorrector.metaphone("soren") == NameCorrector.metaphone("suren"))
        #expect(NameCorrector.metaphone("issa") == NameCorrector.metaphone("isa"))
        let a = NameCorrector.metaphone("sasnowski")
        let b = NameCorrector.metaphone("sosnovsky")
        #expect(NameCorrector.damerauLevenshtein(a, b) <= 1)
    }

    @Test func damerauHandlesTransposition() {
        #expect(NameCorrector.damerauLevenshtein("sarah", "sraah") == 1)
        #expect(NameCorrector.damerauLevenshtein("abc", "abc") == 0)
        #expect(NameCorrector.damerauLevenshtein("", "abc") == 3)
    }
}
