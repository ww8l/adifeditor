import Testing
import Foundation
@testable import ADIFKit

/// What an edit does to the data.
///
/// These sit next to the round-trip suite on purpose. §11's bar — no field lost, an
/// unedited file byte-identical — is easy to hold while a file is only being read; the
/// moment the grid can change a record, the same bar has to survive the change and the
/// undo of it. Every case here is one the writer would otherwise get quietly wrong.
@Suite("Editing")
struct EditingTests {

    private func parse(_ text: String) throws -> ADIFDocument {
        try ADIFParser.parse(Data(text.utf8))
    }

    private func text(_ document: ADIFDocument) -> String {
        String(decoding: ADIFWriter.write(document), as: UTF8.self)
    }

    // MARK: - Changing a value

    @Test("editing a value leaves the rest of the record alone")
    func editKeepsEverythingElse() throws {
        var document = try parse("<CALL:5>W1ABC <BAND:3>20M <MODE:3>FT8 <EOR>\n")
        let edited = try #require(document.recordBySettingValue("K2XYZ",
                                                                forColumn: "CALL",
                                                                inRecordAt: 0))
        document.records[0] = edited

        #expect(text(document) == "<CALL:5>K2XYZ <BAND:3>20M <MODE:3>FT8 <EOR>\n")
    }

    @Test("an edit that changes nothing is not an edit")
    func noOpEditIsRejected() throws {
        let document = try parse("<CALL:5>W1ABC<EOR>\n")
        #expect(document.recordBySettingValue("W1ABC", forColumn: "CALL", inRecordAt: 0) == nil)
    }

    @Test("editing a field keeps the file's spelling of its name")
    func editPreservesSpelling() throws {
        var document = try parse("<call:5>W1ABC <band:3>20M <eor>\n")
        let edited = try #require(document.recordBySettingValue("K2XYZ",
                                                                forColumn: "CALL",
                                                                inRecordAt: 0))
        document.records[0] = edited

        #expect(text(document) == "<call:5>K2XYZ <band:3>20M <eor>\n",
                "decision 3: an edited field is still spelled the way the file spelled it")
    }

    @Test("editing recomputes LENGTH from the new value")
    func editRecomputesLength() throws {
        var document = try parse("<CALL:5>W1ABC<EOR>\n")
        let edited = try #require(document.recordBySettingValue("VE7ABCD",
                                                                forColumn: "CALL",
                                                                inRecordAt: 0))
        document.records[0] = edited

        #expect(text(document) == "<CALL:7>VE7ABCD<EOR>\n")
    }

    @Test("a value with non-ASCII characters counts scalars, not bytes")
    func editCountsScalars() throws {
        var document = try parse("<NAME:3>Bob<EOR>\n")
        let edited = try #require(document.recordBySettingValue("Jörg",
                                                                forColumn: "NAME",
                                                                inRecordAt: 0))
        document.records[0] = edited

        #expect(text(document) == "<NAME:4>Jörg<EOR>\n",
                "the ö is one character and two bytes; LENGTH is characters (§8)")
    }

    // MARK: - Clearing a cell (decision 2)

    @Test("clearing a cell removes the field")
    func clearingRemovesTheField() throws {
        var document = try parse("<CALL:5>W1ABC <COMMENT:5>Hello <EOR>\n")
        let edited = try #require(document.recordBySettingValue("",
                                                                forColumn: "COMMENT",
                                                                inRecordAt: 0))
        document.records[0] = edited

        #expect(!edited.hasField("COMMENT"),
                "decision 2: a value the user deletes is an edit, and the field goes")
        #expect(text(document) == "<CALL:5>W1ABC <EOR>\n")
    }

    @Test("a zero-length field the user never touched survives")
    func untouchedEmptyFieldSurvives() throws {
        let source = "<CALL:5>W1ABC <COMMENT:0> <EOR>\n"
        let document = try parse(source)

        #expect(document.recordBySettingValue("", forColumn: "COMMENT", inRecordAt: 0) == nil,
                "clearing an already-empty cell is not an edit, so <COMMENT:0> stays")
        #expect(text(document) == source)
    }

    @Test("clearing a cell whose field is absent does nothing")
    func clearingAnAbsentFieldDoesNothing() throws {
        let document = try parse("<CALL:5>W1ABC<EOR>\n")
        #expect(document.recordBySettingValue("", forColumn: "COMMENT", inRecordAt: 0) == nil)
    }

    // MARK: - Adding a field

    @Test("typing into an empty cell adds the field to that record only")
    func typingAddsTheField() throws {
        var document = try parse("<CALL:5>W1ABC <EOR>\n<CALL:5>K2XYZ <EOR>\n")
        let edited = try #require(document.recordBySettingValue("US-1234",
                                                                forColumn: "MY_SIG_INFO",
                                                                inRecordAt: 0))
        document.records[0] = edited

        #expect(text(document) == "<CALL:5>W1ABC <MY_SIG_INFO:7>US-1234 <EOR>\n"
                                + "<CALL:5>K2XYZ <EOR>\n")
    }

    @Test("an added field is spelled the way the rest of the file spells that field")
    func addedFieldFollowsTheFilesSpelling() throws {
        // The second record carries the field in lower case; the first does not carry it
        // at all. Adding it to the first must not shout at the file.
        var document = try parse("<call:5>W1ABC <eor>\n<call:5>K2XYZ <my_sig_info:7>US-0001 <eor>\n")
        let edited = try #require(document.recordBySettingValue("US-1234",
                                                                forColumn: "MY_SIG_INFO",
                                                                inRecordAt: 0))
        document.records[0] = edited

        #expect(text(document).hasPrefix("<call:5>W1ABC <my_sig_info:7>US-1234 <eor>"),
                "decision 3")
    }

    @Test("an added field matches the record's own separator style")
    func addedFieldMatchesSeparators() throws {
        // No space between fields in this file; the added field must not introduce one.
        var document = try parse("<CALL:5>W1ABC<BAND:3>20M<EOR>\n")
        let edited = try #require(document.recordBySettingValue("US-1234",
                                                                forColumn: "MY_SIG_INFO",
                                                                inRecordAt: 0))
        document.records[0] = edited

        #expect(text(document) == "<CALL:5>W1ABC<BAND:3>20M<MY_SIG_INFO:7>US-1234<EOR>\n")
    }

    // MARK: - Undo

    @Test("undoing an edit restores the file byte for byte", arguments: [
        ("<CALL:5>W1ABC <BAND:3>20M <EOR>\n", "CALL", "K2XYZ"),
        ("<call:5>W1ABC <comment:5>Hello <eor>\n", "COMMENT", ""),
        ("<CALL:5>W1ABC <EOR>\n", "MY_SIG_INFO", "US-1234"),
        ("<CALL:5>W1ABC <COMMENT:0> <EOR>\n", "COMMENT", "Nice signal"),
    ])
    func undoRestoresBytes(source: String, column: String, newValue: String) throws {
        var document = try parse(source)

        // The app's undo snapshots the whole record rather than the field's old text,
        // because a cleared field restored from a string alone would come back in the
        // wrong position with the wrong spelling. This is that snapshot.
        let original = document.records[0]

        let edited = try #require(document.recordBySettingValue(newValue,
                                                                forColumn: column,
                                                                inRecordAt: 0))
        document.records[0] = edited
        #expect(text(document) != source, "the edit should have changed something")

        document.records[0] = original
        #expect(text(document) == source, "§6.2a: undo has to land back on the exact bytes")
    }

    // MARK: - Bounds

    @Test("editing a row that does not exist is refused, not fatal")
    func outOfRangeRowIsRefused() throws {
        let document = try parse("<CALL:5>W1ABC<EOR>\n")
        #expect(document.recordBySettingValue("X", forColumn: "CALL", inRecordAt: 7) == nil)
        #expect(document.recordBySettingValue("X", forColumn: "CALL", inRecordAt: -1) == nil)
    }
}
