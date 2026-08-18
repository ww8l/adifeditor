import Testing
import Foundation
@testable import ADIFKit

/// Finding text in a log, and stepping through the matches.
///
/// Find changes nothing, so the stakes are lower than most of this suite. What is worth
/// testing is the wrapping: the cases that go wrong are the ends of the list, a single
/// match, no matches, and starting from a row that already matches.
@Suite("Find")
struct FindTests {

    private func parse(_ text: String) throws -> ADIFDocument {
        try ADIFParser.parse(Data(text.utf8))
    }

    private func log() throws -> ADIFDocument {
        try parse("""
            <CALL:5>W1ABC <BAND:3>20M <COMMENT:5>first <EOR>
            <CALL:5>K2XYZ <BAND:3>40M <EOR>
            <CALL:5>W3ABC <BAND:3>20M <EOR>
            <CALL:5>K4GHI <BAND:3>40M <EOR>

            """)
    }

    // MARK: - Matching

    @Test("finds every record holding the text, in any column")
    func findsAcrossColumns() throws {
        let document = try log()

        #expect(document.find("ABC").rows == [0, 2])
        #expect(document.find("40M").rows == [1, 3])
        #expect(document.find("first").rows == [0])
    }

    @Test("matching ignores case")
    func ignoresCase() throws {
        #expect(try log().find("w1abc").rows == [0])
    }

    @Test("part of a value is enough")
    func matchesSubstrings() throws {
        #expect(try log().find("XY").rows == [1])
    }

    @Test("field names are not searched")
    func doesNotMatchFieldNames() throws {
        // Every record has a CALL field. Typing "CALL" should find the one QSO that
        // mentions it in a value, not the whole log.
        let document = try parse("""
            <CALL:5>W1ABC <EOR>
            <CALL:5>K2XYZ <COMMENT:9>bad call <EOR>

            """)
        #expect(document.find("CALL").rows == [1])
    }

    @Test("searching for nothing matches nothing")
    func emptyTextMatchesNothing() throws {
        // An empty find field is not a search for every record; it is not a search.
        #expect(try log().find("").isEmpty)
    }

    @Test("text nothing holds matches nothing")
    func noMatches() throws {
        #expect(try log().find("ZZZZ").isEmpty)
    }

    @Test("finding does not modify the log")
    func findingIsNotAnEdit() throws {
        let source = "<CALL:5>W1ABC <EOR>\n<CALL:5>K2XYZ <EOR>\n"
        let document = try parse(source)

        _ = document.find("W1")

        #expect(String(decoding: ADIFWriter.write(document), as: UTF8.self) == source)
    }

    // MARK: - Stepping

    @Test("next steps forward and wraps at the end")
    func nextWraps() {
        let matches = FindMatches(rows: [1, 4, 7])

        #expect(matches.next(after: nil) == 1, "nothing selected starts at the top")
        #expect(matches.next(after: 1) == 4)
        #expect(matches.next(after: 4) == 7)
        #expect(matches.next(after: 7) == 1, "past the last match, back to the first")
    }

    @Test("previous steps back and wraps at the front")
    func previousWraps() {
        let matches = FindMatches(rows: [1, 4, 7])

        #expect(matches.previous(before: nil) == 7, "nothing selected starts at the bottom")
        #expect(matches.previous(before: 7) == 4)
        #expect(matches.previous(before: 4) == 1)
        #expect(matches.previous(before: 1) == 7, "before the first match, round to the last")
    }

    @Test("stepping from a row between matches lands on the right side of it")
    func stepsFromANonMatch() {
        let matches = FindMatches(rows: [1, 7])

        #expect(matches.next(after: 4) == 7)
        #expect(matches.previous(before: 4) == 1)
    }

    @Test("stepping from a row before or after every match still wraps")
    func stepsFromOutsideTheRange() {
        let matches = FindMatches(rows: [3, 5])

        #expect(matches.next(after: 9) == 3)
        #expect(matches.previous(before: 0) == 5)
    }

    @Test("one match means Find Next returns to it rather than nothing")
    func singleMatch() {
        let matches = FindMatches(rows: [2])

        #expect(matches.next(after: 2) == 2)
        #expect(matches.previous(before: 2) == 2)
    }

    @Test("stepping through no matches goes nowhere instead of trapping")
    func steppingWithNoMatches() {
        let matches = FindMatches()

        #expect(matches.next(after: nil) == nil)
        #expect(matches.next(after: 3) == nil)
        #expect(matches.previous(before: 3) == nil)
    }

    // MARK: - Folding

    /// The reason `.diacriticInsensitive` is in the search options, written down so a
    /// tidy-up cannot remove it silently — dropping it used to pass the whole suite,
    /// because every other string in this file is ASCII.
    ///
    /// An operator types on the keyboard in front of them. A log of European contacts is
    /// full of names and QTHs they have no key for, and a search that made them produce
    /// `ü` before it would find `Grüße` would be a search they stopped using.
    @Test("a search matches through accents the operator cannot type", arguments: [
        "grusse", "GRUSSE", "Grüße", "gruße", "russ"
    ])
    func foldsDiacritics(query: String) throws {
        let log = try parse("""
            <CALL:5>DL1AB <COMMENT:16>Grüße aus Köln <EOR>
            <CALL:5>W1ABC <COMMENT:5>plain <EOR>

            """)

        #expect(log.find(query).rows == [0])
    }

    @Test("folding accents does not make everything match everything")
    func foldingIsNotFuzzy() throws {
        let log = try parse("""
            <CALL:5>DL1AB <COMMENT:16>Grüße aus Köln <EOR>
            <CALL:5>W1ABC <COMMENT:5>plain <EOR>

            """)

        #expect(log.find("grasse").isEmpty, "a different vowel is a different word")
        #expect(log.find("koln").rows == [0])
        #expect(log.find("kolner").isEmpty)
    }

    // MARK: - Counting

    @Test("a match reports its place in the list, counting from one")
    func ordinals() {
        let matches = FindMatches(rows: [1, 4, 7])

        #expect(matches.ordinal(of: 1) == 1)
        #expect(matches.ordinal(of: 7) == 3)
        #expect(matches.ordinal(of: 5) == nil, "not a match, so no place in the list")
        #expect(matches.count == 3)
    }
}
