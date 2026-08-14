import Testing
import Foundation
import ADIFKit
@testable import QRZKit

/// Turning QRZ records into proposed edits.
///
/// Two of these carry the weight of §6.3 — the app fills empty cells and never overwrites
/// — which used to be a rule about the POTA stamp and is now also the rule keeping an
/// external service from rewriting a log the operator corrected by hand.
@Suite("QRZ lookup")
struct QRZLookupTests {

    private func parse(_ text: String) throws -> ADIFDocument {
        try ADIFParser.parse(Data(text.utf8))
    }

    private func record(_ elements: [String: String]) -> QRZCallsign {
        QRZCallsign(elements: elements)
    }

    /// A full QRZ record for W1ABC, as the mapping sees it.
    private var w1abc: QRZCallsign {
        record([
            "call": "W1ABC",
            "name_fmt": "John Q Public",
            "addr2": "Springfield",
            "state": "MA",
            "county": "Hampden",
            "grid": "FN32aa",
            "land": "United States",
            "dxcc": "291",
            "cqzone": "5",
            "ituzone": "8"
        ])
    }

    // MARK: - Which callsigns get looked up

    @Test("callsigns are uppercased and asked for once each")
    func dedupesCallsigns() throws {
        // A park activator worked on four bands is one lookup, not four.
        let document = try parse("""
            <CALL:5>W1ABC <BAND:3>20M <EOR>
            <CALL:5>K2XYZ <BAND:3>20M <EOR>
            <CALL:5>w1abc <BAND:3>40M <EOR>
            <CALL:5>W1ABC <BAND:3>15M <EOR>

            """)

        #expect(QRZLookup.callsigns(in: document, rows: IndexSet(0..<4)) == ["W1ABC", "K2XYZ"])
    }

    @Test("only the selected rows are looked up")
    func respectsSelection() throws {
        let document = try parse("""
            <CALL:5>W1ABC <EOR>
            <CALL:5>K2XYZ <EOR>
            <CALL:5>N3DEF <EOR>

            """)

        #expect(QRZLookup.callsigns(in: document, rows: IndexSet([0, 2])) == ["W1ABC", "N3DEF"])
    }

    @Test("a row with no callsign is skipped rather than looked up blank")
    func skipsBlankCallsigns() throws {
        let document = try parse("""
            <CALL:0> <BAND:3>20M <EOR>
            <BAND:3>20M <EOR>
            <CALL:5>W1ABC <EOR>

            """)

        #expect(QRZLookup.callsigns(in: document, rows: IndexSet(0..<3)) == ["W1ABC"])
    }

    @Test("row numbers outside the log are ignored, not trapped on")
    func ignoresOutOfRangeRows() throws {
        let document = try parse("<CALL:5>W1ABC <EOR>\n")

        #expect(QRZLookup.callsigns(in: document, rows: IndexSet([0, 5, 99])) == ["W1ABC"])
    }

    // MARK: - §6.3, the rule that matters

    @Test("a field that already has a value is never proposed")
    func neverOverwrites() throws {
        // The operator corrected this name by hand because QRZ has it wrong. A lookup
        // must not quietly put it back.
        let document = try parse("""
            <CALL:5>W1ABC <NAME:4>Jack <STATE:2>NH <EOR>

            """)
        let fills = QRZLookup.proposedFills(in: document,
                                            rows: IndexSet([0]),
                                            results: ["W1ABC": w1abc])

        #expect(!fills.contains { $0.field == "NAME" })
        #expect(!fills.contains { $0.field == "STATE" })
        #expect(fills.contains { $0.field == "GRIDSQUARE" && $0.value == "FN32aa" })
    }

    @Test("a present-but-empty field is fillable")
    func fillsEmptyFields() throws {
        // <NAME:0> is a cell the operator sees as blank, so filling it is filling an
        // empty cell, not overwriting a value.
        let document = try parse("""
            <CALL:5>W1ABC <NAME:0> <EOR>

            """)
        let fills = QRZLookup.proposedFills(in: document,
                                            rows: IndexSet([0]),
                                            results: ["W1ABC": w1abc])

        #expect(fills.contains { $0.field == "NAME" && $0.value == "John Q Public" })
    }

    @Test("a field holding only spaces counts as empty")
    func whitespaceIsEmpty() throws {
        let document = try parse("""
            <CALL:5>W1ABC <NAME:3>    <EOR>

            """)
        let fills = QRZLookup.proposedFills(in: document,
                                            rows: IndexSet([0]),
                                            results: ["W1ABC": w1abc])

        #expect(fills.contains { $0.field == "NAME" })
    }

    @Test("a callsign QRZ did not return contributes nothing")
    func unknownCallsignsContributeNothing() throws {
        let document = try parse("""
            <CALL:5>W1ABC <EOR>
            <CALL:6>ZZ9ZZZ <EOR>

            """)
        let fills = QRZLookup.proposedFills(in: document,
                                            rows: IndexSet([0, 1]),
                                            results: ["W1ABC": w1abc])

        #expect(fills.allSatisfy { $0.row == 0 })
    }

    @Test("every row worked with the same station is filled, not just the first")
    func fillsEveryMatchingRow() throws {
        let document = try parse("""
            <CALL:5>W1ABC <BAND:3>20M <EOR>
            <CALL:5>w1abc <BAND:3>40M <EOR>

            """)
        let fills = QRZLookup.proposedFills(in: document,
                                            rows: IndexSet([0, 1]),
                                            results: ["W1ABC": w1abc])

        #expect(Set(fills.map(\.row)) == [0, 1])
    }

    @Test("the field list narrows what is proposed")
    func respectsFieldFilter() throws {
        let document = try parse("<CALL:5>W1ABC <EOR>\n")
        let fills = QRZLookup.proposedFills(in: document,
                                            rows: IndexSet([0]),
                                            results: ["W1ABC": w1abc],
                                            fields: ["GRIDSQUARE", "STATE"])

        #expect(Set(fills.map(\.field)) == ["GRIDSQUARE", "STATE"])
    }

    @Test("an empty field list proposes nothing")
    func emptyFieldFilterProposesNothing() throws {
        let document = try parse("<CALL:5>W1ABC <EOR>\n")

        #expect(QRZLookup.proposedFills(in: document,
                                        rows: IndexSet([0]),
                                        results: ["W1ABC": w1abc],
                                        fields: []).isEmpty)
    }

    @Test("a sparse QRZ record proposes only what it has")
    func sparseRecord() throws {
        let document = try parse("<CALL:5>K2XYZ <EOR>\n")
        let fills = QRZLookup.proposedFills(
            in: document,
            rows: IndexSet([0]),
            results: ["K2XYZ": record(["name": "Springfield Radio Club", "dxcc": "291"])])

        #expect(fills.map(\.field) == ["NAME", "DXCC"])
    }

    // MARK: - Applying

    @Test("applying the proposals writes exactly them")
    func appliesFills() throws {
        let document = try parse("<CALL:5>W1ABC <BAND:3>20M <EOR>\n")
        let fills = QRZLookup.proposedFills(in: document,
                                            rows: IndexSet([0]),
                                            results: ["W1ABC": w1abc],
                                            fields: ["NAME", "GRIDSQUARE"])
        let records = QRZLookup.records(in: document, applying: fills)

        #expect(records[0]["NAME"] == "John Q Public")
        #expect(records[0]["GRIDSQUARE"] == "FN32aa")
        #expect(records[0]["STATE"] == nil, "nothing that was not proposed")
        #expect(records[0]["CALL"] == "W1ABC")
        #expect(records[0]["BAND"] == "20M")
    }

    @Test("several fills on one row all survive")
    func multipleFillsOnOneRow() throws {
        // Each fill is computed against the record as the previous one left it. Applying
        // them all against the original would keep only the last.
        let document = try parse("<CALL:5>W1ABC <EOR>\n")
        let fills = QRZLookup.proposedFills(in: document,
                                            rows: IndexSet([0]),
                                            results: ["W1ABC": w1abc])
        let records = QRZLookup.records(in: document, applying: fills)

        #expect(records[0]["NAME"] == "John Q Public")
        #expect(records[0]["QTH"] == "Springfield")
        #expect(records[0]["STATE"] == "MA")
        #expect(records[0]["CNTY"] == "MA,Hampden")
        #expect(records[0]["GRIDSQUARE"] == "FN32aa")
        #expect(records[0]["COUNTRY"] == "United States")
        #expect(records[0]["DXCC"] == "291")
        #expect(records[0]["CQZ"] == "5")
        #expect(records[0]["ITUZ"] == "8")
    }

    @Test("a filled field lands where the file already keeps that column")
    func placesFieldByColumnOrder() throws {
        // Decision 14: appending to the record instead would drag the column to the far
        // right of the grid, which is the bug the owner found within minutes of cell
        // editing existing. A lookup fills the same way typing does.
        let document = try parse("""
            <CALL:5>W1ABC <EOR>
            <CALL:5>K2XYZ <NAME:4>Kate <BAND:3>20M <EOR>

            """)
        let fills = QRZLookup.proposedFills(in: document,
                                            rows: IndexSet([0]),
                                            results: ["W1ABC": w1abc],
                                            fields: ["NAME"])
        let records = QRZLookup.records(in: document, applying: fills)

        #expect(records[0].fields.map(\.name) == ["CALL", "NAME"])
    }

    @Test("the file's own spelling of a field is kept")
    func keepsFileSpelling() throws {
        // Decision 3. A lower-case file should not acquire a shouting NAME among its
        // fields because QRZKit spells its mappings in upper case.
        let document = try parse("""
            <call:5>W1ABC <name:4>Kate <EOR>
            <call:5>K2XYZ <EOR>

            """)
        let fills = QRZLookup.proposedFills(in: document,
                                            rows: IndexSet([1]),
                                            results: ["K2XYZ": record(["name_fmt": "Karl"])])
        let records = QRZLookup.records(in: document, applying: fills)

        #expect(records[1].fields.map(\.spelling) == ["call", "name"])
    }

    @Test("applying nothing changes nothing")
    func applyingNothingIsANoOp() throws {
        let document = try parse("<CALL:5>W1ABC <EOR>\n")

        #expect(QRZLookup.records(in: document, applying: []) == document.records)
    }

    @Test("a proposal for a row that no longer exists is ignored")
    func staleRowIsIgnored() throws {
        // The operator can delete rows between the sheet appearing and confirming it.
        let document = try parse("<CALL:5>W1ABC <EOR>\n")
        let records = QRZLookup.records(
            in: document,
            applying: [ProposedFill(row: 7, field: "NAME", value: "Nobody")])

        #expect(records == document.records)
    }

    @Test("an untouched log still round-trips byte for byte")
    func doesNotDisturbTheRestOfTheFile() throws {
        // §6.2a. A lookup that filled one cell must not have quietly re-serialized
        // anything else — the whole point of routing through the same edit primitive.
        let source = "Header text\n<EOH>\n<CALL:5>W1ABC <COMMENT:0> <EOR>\n"
        var document = try parse(source)
        document.records = QRZLookup.records(in: document, applying: [])

        #expect(String(decoding: ADIFWriter.write(document), as: UTF8.self) == source)
    }

    @Test("proposals are listed in row order, then in field order")
    func stableOrdering() throws {
        // The review sheet shows these in the order they arrive, and an operator scanning
        // eighty of them needs the order to be the one they are looking at in the grid.
        let document = try parse("""
            <CALL:5>K2XYZ <EOR>
            <CALL:5>W1ABC <EOR>

            """)
        let fills = QRZLookup.proposedFills(
            in: document,
            rows: IndexSet([0, 1]),
            results: ["W1ABC": w1abc, "K2XYZ": record(["name_fmt": "Kate", "state": "VT"])])

        #expect(fills.map(\.row) == fills.map(\.row).sorted())
        #expect(fills.prefix(2).map(\.field) == ["NAME", "STATE"])
    }
}
