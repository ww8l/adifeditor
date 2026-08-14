import Testing
import Foundation
@testable import ADIFKit

/// Finding duplicate QSOs.
///
/// The stakes: every row this reports is a row the operator is about to delete from a log
/// they may then upload. A false positive loses a contact.
@Suite("Duplicates")
struct DuplicateTests {

    private func parse(_ text: String) throws -> ADIFDocument {
        try ADIFParser.parse(Data(text.utf8))
    }

    private static let defaultFields = ["QSO_DATE", "CALL", "BAND", "MODE"]

    @Test("identical QSOs are found, and the first one is the keeper")
    func findsDuplicates() throws {
        let document = try parse("""
            <CALL:5>W1ABC <QSO_DATE:8>20260209 <BAND:3>20M <MODE:3>FT8 <EOR>
            <CALL:5>K2XYZ <QSO_DATE:8>20260209 <BAND:3>20M <MODE:3>FT8 <EOR>
            <CALL:5>W1ABC <QSO_DATE:8>20260209 <BAND:3>20M <MODE:3>FT8 <EOR>

            """)
        let groups = document.duplicateGroups(matching: Self.defaultFields)

        #expect(groups == [DuplicateGroup(original: 0, duplicates: [2])])
        #expect(document.duplicateRows(matching: Self.defaultFields) == IndexSet([2]))
    }

    @Test("a QSO differing in any compared field is not a duplicate")
    func respectsEveryField() throws {
        // Same station, same day, different band — a real second contact, and deleting it
        // would lose a QSO the operator earned.
        let document = try parse("""
            <CALL:5>W1ABC <QSO_DATE:8>20260209 <BAND:3>20M <MODE:3>FT8 <EOR>
            <CALL:5>W1ABC <QSO_DATE:8>20260209 <BAND:3>40M <MODE:3>FT8 <EOR>
            <CALL:5>W1ABC <QSO_DATE:8>20260210 <BAND:3>20M <MODE:3>FT8 <EOR>
            <CALL:5>W1ABC <QSO_DATE:8>20260209 <BAND:3>20M <MODE:3>FT4 <EOR>

            """)
        #expect(document.duplicateRows(matching: Self.defaultFields).isEmpty)
    }

    @Test("three of the same collapse to one keeper and two duplicates")
    func handlesRuns() throws {
        let document = try parse("""
            <CALL:5>W1ABC <BAND:3>20M <EOR>
            <CALL:5>W1ABC <BAND:3>20M <EOR>
            <CALL:5>W1ABC <BAND:3>20M <EOR>

            """)
        #expect(document.duplicateGroups(matching: ["CALL", "BAND"])
                == [DuplicateGroup(original: 0, duplicates: [1, 2])])
    }

    @Test("several independent groups are each reported")
    func handlesMultipleGroups() throws {
        let document = try parse("""
            <CALL:5>W1ABC <BAND:3>20M <EOR>
            <CALL:5>K2XYZ <BAND:3>20M <EOR>
            <CALL:5>W1ABC <BAND:3>20M <EOR>
            <CALL:5>K2XYZ <BAND:3>20M <EOR>

            """)
        #expect(document.duplicateGroups(matching: ["CALL", "BAND"]) == [
            DuplicateGroup(original: 0, duplicates: [2]),
            DuplicateGroup(original: 1, duplicates: [3])
        ])
    }

    @Test("comparison ignores case, because a callsign is a callsign")
    func caseInsensitive() throws {
        let document = try parse("""
            <CALL:5>W1ABC <BAND:3>20M <EOR>
            <CALL:5>w1abc <BAND:3>20m <EOR>

            """)
        #expect(document.duplicateRows(matching: ["CALL", "BAND"]) == IndexSet([1]))
    }

    @Test("an absent field and an empty one compare equal")
    func absentMatchesEmpty() throws {
        // The log does not distinguish "no band recorded" from "no band recorded".
        let document = try parse("""
            <CALL:5>W1ABC <EOR>
            <CALL:5>W1ABC <BAND:0> <EOR>

            """)
        #expect(document.duplicateRows(matching: ["CALL", "BAND"]) == IndexSet([1]))
    }

    @Test("comparing on no fields reports nothing, not everything")
    func emptyFieldListIsSafe() throws {
        // Matching on nothing means every record matches every other. Reporting the whole
        // log as duplicates of row 1 is the single most destructive thing this could do.
        let document = try parse("""
            <CALL:5>W1ABC <EOR>
            <CALL:5>K2XYZ <EOR>

            """)
        #expect(document.duplicateGroups(matching: []).isEmpty)
        #expect(document.duplicateRows(matching: []).isEmpty)
    }

    @Test("a field no record carries makes every QSO look alike, and that is honest")
    func missingFieldMatchesEverything() throws {
        // Every record has "" for a field none of them carry, so the only thing keeping
        // them apart is the other fields. Comparing on the missing field alone genuinely
        // does make them all duplicates — which is why the interface shows the operator
        // what would be deleted before deleting it.
        let document = try parse("""
            <CALL:5>W1ABC <EOR>
            <CALL:5>K2XYZ <EOR>

            """)
        #expect(document.duplicateRows(matching: ["NOTES"]) == IndexSet([1]))
        #expect(document.duplicateRows(matching: ["NOTES", "CALL"]).isEmpty)
    }

    @Test("a separator inside a value cannot fake a match")
    func valuesCannotCollide() throws {
        // Joining values into one string would make ("A", "B|C") and ("A|B", "C") the
        // same key for any separator that can appear in a value — and COMMENT can hold
        // anything at all.
        let document = try parse("""
            <CALL:1>A <COMMENT:3>B|C <EOR>
            <CALL:3>A|B <COMMENT:1>C <EOR>

            """)
        #expect(document.duplicateRows(matching: ["CALL", "COMMENT"]).isEmpty)
    }

    @Test("an empty log has no duplicates")
    func emptyLog() throws {
        #expect(try parse("").duplicateRows(matching: Self.defaultFields).isEmpty)
    }

    @Test("finding duplicates does not modify the log")
    func nonDestructive() throws {
        let source = "<CALL:5>W1ABC <EOR>\n<CALL:5>W1ABC <EOR>\n"
        let document = try parse(source)
        _ = document.duplicateGroups(matching: ["CALL"])

        #expect(String(decoding: ADIFWriter.write(document), as: UTF8.self) == source)
    }

    @Test("deleting the reported rows leaves exactly one of each QSO")
    func deletingLeavesOneOfEach() throws {
        var document = try parse("""
            <CALL:5>W1ABC <BAND:3>20M <EOR>
            <CALL:5>K2XYZ <BAND:3>20M <EOR>
            <CALL:5>W1ABC <BAND:3>20M <EOR>
            <CALL:5>W1ABC <BAND:3>20M <EOR>

            """)
        let rows = document.duplicateRows(matching: ["CALL", "BAND"])
        document.records = document.recordsByDeleting(at: rows)

        #expect(document.records.map { $0["CALL"] } == ["W1ABC", "K2XYZ"])
        #expect(document.duplicateRows(matching: ["CALL", "BAND"]).isEmpty,
                "and running it again finds nothing left to do")
    }
}
