import Testing
import Foundation
@testable import ADIFKit

/// Replacing text, and deleting a column (issue #41).
///
/// Both change many values at once, which is exactly where §6.2a's bar is easiest to
/// drop: the fields that were *not* meant to change have to come out with every byte they
/// went in with.
@Suite("Replace")
struct ReplaceTests {

    private func parse(_ text: String) throws -> ADIFDocument {
        try ADIFParser.parse(Data(text.utf8))
    }

    private func text(_ records: [ADIFRecord], from document: ADIFDocument) -> String {
        var edited = document
        edited.records = records
        return String(decoding: ADIFWriter.write(edited), as: UTF8.self)
    }

    private let source = """
        <CALL:5>W1ABC <MY_SIG_INFO:7>US-1234 <COMMENT:10>US-1234 ok <EOR>
        <CALL:5>K2XYZ <MY_SIG_INFO:7>US-1234 <EOR>
        <CALL:5>W3ABC <MY_SIG_INFO:7>US-9999 <EOR>

        """

    @Test("replaces in every field of the rows asked for, and nowhere else")
    func confinedToRows() throws {
        let document = try parse(source)
        let records = document.recordsByReplacing("US-1234", with: "US-5678",
                                                  inRecordsAt: IndexSet(integer: 0))

        #expect(text(records, from: document) == """
            <CALL:5>W1ABC <MY_SIG_INFO:7>US-5678 <COMMENT:10>US-5678 ok <EOR>
            <CALL:5>K2XYZ <MY_SIG_INFO:7>US-1234 <EOR>
            <CALL:5>W3ABC <MY_SIG_INFO:7>US-9999 <EOR>

            """)
    }

    @Test("matches the way find does, and writes the replacement as typed")
    func matchesLikeFind() throws {
        let document = try parse(source)
        let all = IndexSet(document.find("us-1234").rows)
        #expect(all == IndexSet([0, 1]))

        let records = document.recordsByReplacing("us-1234", with: "US-5678", inRecordsAt: all)
        #expect(records.map { $0["MY_SIG_INFO"] } == ["US-5678", "US-5678", "US-9999"])
    }

    @Test("a changed value gets a fresh LENGTH and keeps its spelling, type and place")
    func changedFieldKeepsItsShape() throws {
        let document = try parse("<call:005:S>W1ABC <qso_date:8:D>20260815 <EOR>\n")
        let records = document.recordsByReplacing("W1ABC", with: "W1ABCD",
                                                  inRecordsAt: IndexSet(integer: 0))

        #expect(text(records, from: document)
                == "<call:6:S>W1ABCD <qso_date:8:D>20260815 <EOR>\n")
    }

    @Test("field names are not replaced")
    func namesAreLeftAlone() throws {
        let document = try parse("<CALL:5>W1ABC <COMMENT:4>call <EOR>\n")
        let records = document.recordsByReplacing("call", with: "QSO",
                                                  inRecordsAt: IndexSet(integer: 0))

        #expect(text(records, from: document) == "<CALL:5>W1ABC <COMMENT:3>QSO <EOR>\n")
    }

    @Test("a value replaced down to nothing removes the field, as clearing the cell does")
    func emptiedValueRemovesField() throws {
        let document = try parse("<CALL:5>W1ABC <MODE:3>FT8 <BAND:3>20M <EOR>\n")
        let records = document.recordsByReplacing("ft8", with: "",
                                                  inRecordsAt: IndexSet(integer: 0))

        #expect(text(records, from: document) == "<CALL:5>W1ABC <BAND:3>20M <EOR>\n")
    }

    @Test("a zero-length field nothing matched survives")
    func untouchedZeroLengthSurvives() throws {
        let original = "<CALL:5>W1ABC <COMMENT:0> <EOR>\n"
        let document = try parse(original)
        let records = document.recordsByReplacing("W1", with: "K1",
                                                  inRecordsAt: IndexSet(integer: 0))

        #expect(text(records, from: document) == "<CALL:5>K1ABC <COMMENT:0> <EOR>\n")
    }

    @Test("replacing nothing, or in rows that do not exist, changes nothing")
    func noOps() throws {
        let document = try parse(source)

        #expect(document.recordsByReplacing("", with: "X",
                                            inRecordsAt: IndexSet([0, 1, 2])) == document.records)
        #expect(document.recordsByReplacing("US-1234", with: "X",
                                            inRecordsAt: IndexSet([7, 99])) == document.records)
        #expect(document.recordsByReplacing("ZZZ", with: "X",
                                            inRecordsAt: IndexSet([0, 1, 2])) == document.records)
    }
}

@Suite("Delete column")
struct DeleteColumnTests {

    private func parse(_ text: String) throws -> ADIFDocument {
        try ADIFParser.parse(Data(text.utf8))
    }

    private func text(_ records: [ADIFRecord], from document: ADIFDocument) -> String {
        var edited = document
        edited.records = records
        return String(decoding: ADIFWriter.write(edited), as: UTF8.self)
    }

    @Test("removes the field from every record and leaves the rest byte-identical")
    func removesEverywhere() throws {
        let document = try parse("""
            ADIF export <EOH>
            <call:5>W1ABC <Comment:2>hi <mode:3>FT8 <eor>
            <call:5>K2XYZ <mode:3>FT8 <eor>
            <call:5>W3ABC <COMMENT:0> <mode:3>FT8 <eor>

            """)
        let records = document.recordsByDeletingColumn("COMMENT")

        #expect(text(records, from: document) == """
            ADIF export <EOH>
            <call:5>W1ABC <mode:3>FT8 <eor>
            <call:5>K2XYZ <mode:3>FT8 <eor>
            <call:5>W3ABC <mode:3>FT8 <eor>

            """)
        var edited = document
        edited.records = records
        #expect(!edited.columnNames.contains("COMMENT"))
    }

    @Test("a record carrying the field twice loses both copies")
    func removesDuplicates() throws {
        let document = try parse("<CALL:5>W1ABC <NOTES:1>a <NOTES:1>b <EOR>\n")
        let records = document.recordsByDeletingColumn("notes")

        #expect(text(records, from: document) == "<CALL:5>W1ABC <EOR>\n")
    }

    @Test("deleting a column no record carries changes nothing")
    func absentColumn() throws {
        let document = try parse("<CALL:5>W1ABC <EOR>\n")
        #expect(document.recordsByDeletingColumn("STATE") == document.records)
    }
}
