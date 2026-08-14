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

    @Test("a re-added field goes back where the other records keep it")
    func reAddedFieldReturnsToItsPosition() throws {
        var document = try parse("""
            <CALL:5>W1ABC <GRIDSQUARE:4>EN53 <MODE:3>FT8 <EOR>
            <CALL:5>K2XYZ <GRIDSQUARE:4>EM10 <MODE:3>FT8 <EOR>

            """)

        let cleared = try #require(document.recordBySettingValue("",
                                                                 forColumn: "GRIDSQUARE",
                                                                 inRecordAt: 0))
        document.records[0] = cleared

        let restored = try #require(document.recordBySettingValue("DM45",
                                                                  forColumn: "GRIDSQUARE",
                                                                  inRecordAt: 0))
        document.records[0] = restored

        #expect(restored.fields.map(\.name) == ["CALL", "GRIDSQUARE", "MODE"],
                "not appended to the end of the record")
        #expect(document.columnNames == ["CALL", "GRIDSQUARE", "MODE"],
                "and so the column stays put in the grid")
    }

    @Test("clearing a cell and retyping the same value restores the exact bytes")
    func clearAndRetypeIsByteIdentical() throws {
        let source = """
            <call:5>W1ABC <gridsquare:4>EN53 <mode:3>FT8 <eor>
            <call:5>K2XYZ <gridsquare:4>EM10 <mode:3>FT8 <eor>

            """
        var document = try parse(source)

        let cleared = try #require(document.recordBySettingValue("",
                                                                 forColumn: "GRIDSQUARE",
                                                                 inRecordAt: 0))
        document.records[0] = cleared
        #expect(text(document) != source)

        let retyped = try #require(document.recordBySettingValue("EN53",
                                                                 forColumn: "GRIDSQUARE",
                                                                 inRecordAt: 0))
        document.records[0] = retyped

        // Position, spelling and separator all have to come back for this to hold.
        #expect(text(document) == source)
    }

    @Test("a field no other record carries is added at the end")
    func genuinelyNewFieldGoesLast() throws {
        var document = try parse("<CALL:5>W1ABC <MODE:3>FT8 <EOR>\n")
        let edited = try #require(document.recordBySettingValue("US-1234",
                                                                forColumn: "MY_SIG_INFO",
                                                                inRecordAt: 0))
        document.records[0] = edited

        #expect(edited.fields.map(\.name) == ["CALL", "MODE", "MY_SIG_INFO"],
                "nothing to take a position from, so it goes at the end")
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

    // MARK: - Column order (decision 14)

    @Test("clearing a cell in the first row does not move its column")
    func clearingDoesNotRelocateTheColumn() throws {
        // The bug this pins, reported from the grid: delete row 1's QSL_RCVD and the
        // whole column jumps to the far right, because under §9's original rule the
        // field was no longer "first encountered" until row 2 — behind everything else
        // row 1 carried.
        var document = try parse("""
            <CALL:5>W1ABC <QSL_RCVD:1>N <MODE:3>FT8 <EOR>
            <CALL:5>K2XYZ <QSL_RCVD:1>Y <MODE:3>FT8 <EOR>

            """)
        let before = document.columnNames

        let edited = try #require(document.recordBySettingValue("",
                                                                forColumn: "QSL_RCVD",
                                                                inRecordAt: 0))
        document.records[0] = edited

        #expect(document.columnNames == before)
        #expect(document.columnNames == ["CALL", "QSL_RCVD", "MODE"])
    }

    @Test("a column survives every row losing its value")
    func columnSurvivesBeingClearedEverywhere() throws {
        var document = try parse("<CALL:5>W1ABC <QSL_RCVD:1>N <EOR>\n")
        let edited = try #require(document.recordBySettingValue("",
                                                                forColumn: "QSL_RCVD",
                                                                inRecordAt: 0))
        document.records[0] = edited

        // No record carries it now, so it is genuinely gone from the data. The grid keeps
        // showing the column for the rest of the session because it caches its columns —
        // that is a view concern, not this one.
        #expect(document.columnNames == ["CALL"])
    }

    @Test("a field only some records carry lands where those records put it")
    func mergedColumnOrder() throws {
        let document = try parse("""
            <CALL:5>W1ABC <MODE:3>FT8 <EOR>
            <CALL:5>K2XYZ <MY_SIG_INFO:7>US-1234 <MODE:3>FT8 <EOR>

            """)
        #expect(document.columnNames == ["CALL", "MY_SIG_INFO", "MODE"])
    }

    @Test("column order is stable when records disagree about field order")
    func columnOrderStableUnderDisagreement() throws {
        let document = try parse("""
            <CALL:5>W1ABC <MODE:3>FT8 <BAND:3>20m <EOR>
            <BAND:3>40m <CALL:5>K2XYZ <MODE:3>FT8 <EOR>
            <MODE:2>CW <BAND:3>15m <CALL:5>W3GHI <EOR>

            """)
        #expect(document.columnNames == ["CALL", "MODE", "BAND"],
                "later records reorder nothing; the first record's layout stands")
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

    // MARK: - Sorting

    private func multiDateLog() throws -> ADIFDocument {
        try parse("""
            <CALL:5>W1ABC <QSO_DATE:8>20260213 <TIME_ON:6>222730 <EOR>
            <CALL:5>K2XYZ <QSO_DATE:8>20260209 <TIME_ON:6>222045 <EOR>
            <CALL:5>W3GHI <QSO_DATE:8>20260213 <TIME_ON:6>101500 <EOR>
            <CALL:5>N4JKL <QSO_DATE:8>20260209 <TIME_ON:6>222345 <EOR>

            """)
    }

    @Test("sorting by a column reorders the records")
    func sortAscending() throws {
        let document = try multiDateLog()
        let sorted = document.recordsSorted(byColumn: "QSO_DATE", ascending: true)
        #expect(sorted.map { $0["CALL"] } == ["K2XYZ", "N4JKL", "W1ABC", "W3GHI"])
    }

    @Test("sorting descending reverses it")
    func sortDescending() throws {
        let document = try multiDateLog()
        let sorted = document.recordsSorted(byColumn: "QSO_DATE", ascending: false)
        #expect(sorted.map { $0["CALL"] } == ["W1ABC", "W3GHI", "K2XYZ", "N4JKL"])
    }

    @Test("ties keep their original order")
    func sortIsStableAtScale() throws {
        // Sixty records all tying on the sorted column.
        //
        // Honest note: this assertion cannot currently fail. Swift's `sorted(by:)` is a
        // timsort and stable in practice, so ties hold their order even without the
        // comparator's explicit tiebreak — removing that tiebreak breaks no test here.
        // The tiebreak stays because the standard library documents stability as *not*
        // guaranteed, and the comparator being a strict total order makes the result
        // ours rather than the implementation's. The test pins the behaviour the app
        // depends on; it does not prove where the behaviour comes from.
        let calls = (0..<60).map { String(format: "W%04d", $0) }
        let body = calls
            .map { "<CALL:5>\($0) <QSO_DATE:8>20260213 <EOR>" }
            .joined(separator: "\n")
        let document = try parse(body + "\n")

        let sorted = document.recordsSorted(byColumn: "QSO_DATE", ascending: true)
        #expect(sorted.map { $0["CALL"] } == calls,
                "every record ties, so the sort must not move any of them")
    }

    @Test("sorting is stable, so sorting twice narrows rather than shuffles")
    func sortIsStable() throws {
        let document = try multiDateLog()

        // Sort by time, then by date: within each date the time order has to survive,
        // which is the whole point of prepping an activation log by two columns.
        var staged = document
        staged.records = staged.recordsSorted(byColumn: "TIME_ON", ascending: true)
        let byDateThenTime = staged.recordsSorted(byColumn: "QSO_DATE", ascending: true)

        #expect(byDateThenTime.map { $0["CALL"] } == ["K2XYZ", "N4JKL", "W3GHI", "W1ABC"])
    }

    @Test("records missing the sorted column gather at one end")
    func sortPutsBlanksTogether() throws {
        let document = try parse("""
            <CALL:5>W1ABC <MY_SIG_INFO:7>US-1234 <EOR>
            <CALL:5>K2XYZ <EOR>
            <CALL:5>W3GHI <MY_SIG_INFO:7>US-0001 <EOR>

            """)
        let sorted = document.recordsSorted(byColumn: "MY_SIG_INFO", ascending: true)
        #expect(sorted.map { $0["CALL"] } == ["K2XYZ", "W3GHI", "W1ABC"])
    }

    @Test("sorting loses no record and changes no value")
    func sortPreservesEverything() throws {
        let document = try multiDateLog()
        var sorted = document
        sorted.records = document.recordsSorted(byColumn: "CALL", ascending: false)

        #expect(sorted.records.count == document.records.count)
        #expect(Set(sorted.records.map { $0["CALL"] }) == Set(document.records.map { $0["CALL"] }))

        // Reordering records must not rewrite any of them.
        let restored = sorted.recordsSorted(byColumn: "QSO_DATE", ascending: true)
        var back = document
        back.records = restored
        #expect(Set(text(back).split(separator: "\n")) == Set(text(document).split(separator: "\n")))
    }

    // MARK: - Deleting rows

    @Test("deleting rows removes exactly those rows")
    func deleteRemovesTheRightRecords() throws {
        let document = try multiDateLog()
        let remaining = document.recordsByDeleting(at: IndexSet([0, 2]))
        #expect(remaining.map { $0["CALL"] } == ["K2XYZ", "N4JKL"])
    }

    @Test("deleting a discontiguous selection does not shift the wrong rows out")
    func deleteHandlesDiscontiguousSelection() throws {
        let document = try parse("""
            <CALL:1>A <EOR>
            <CALL:1>B <EOR>
            <CALL:1>C <EOR>
            <CALL:1>D <EOR>
            <CALL:1>E <EOR>

            """)
        // Removing low-to-high would shift indices under itself and take C and E.
        let remaining = document.recordsByDeleting(at: IndexSet([1, 3]))
        #expect(remaining.map { $0["CALL"] } == ["A", "C", "E"])
    }

    @Test("deleting nothing, or rows that do not exist, is harmless")
    func deleteOutOfRangeIsHarmless() throws {
        let document = try multiDateLog()
        #expect(document.recordsByDeleting(at: IndexSet()).count == 4)
        #expect(document.recordsByDeleting(at: IndexSet([99])).count == 4)
    }

    @Test("deleting every row leaves a file with a header and no QSOs")
    func deleteAllLeavesTheHeader() throws {
        var document = try parse("<ADIF_VER:5>3.1.6\n<EOH>\n<CALL:5>W1ABC<EOR>\n")
        document.records = document.recordsByDeleting(at: IndexSet([0]))

        #expect(document.records.isEmpty)
        #expect(text(document) == "<ADIF_VER:5>3.1.6\n<EOH>\n",
                "the header the file arrived with survives its last QSO being deleted")
    }

    // MARK: - Copied fragments (the clipboard format)

    @Test("a headerless fragment of records survives a round trip")
    func fragmentRoundTrips() throws {
        // What Copy puts on the pasteboard: records with no header, since the fragment is
        // part of a log rather than a log. Paste has to get back exactly what was copied,
        // including field spellings and zero-length fields.
        let document = try parse("""
            <ADIF_VER:5>3.1.6
            <EOH>
            <call:5>W1ABC <comment:0> <mode:3>FT8 <EOR>
            <call:5>K2XYZ <mode:3>FT8 <EOR>

            """)

        let fragment = ADIFDocument(header: nil, records: Array(document.records.prefix(2)))
        let copied = String(decoding: ADIFWriter.write(fragment), as: UTF8.self)

        #expect(!copied.uppercased().contains("<EOH>"), "a fragment carries no header")

        let pasted = try parse(copied)
        #expect(pasted.records == document.records)
    }

    @Test("pasting text that is not ADIF yields no records rather than failing")
    func nonADIFPasteYieldsNothing() throws {
        // The pasteboard belongs to the whole system and will hold prose and URLs. That
        // is a disabled Paste, not a parse error (§6.4).
        #expect(try parse("just some text someone copied").records.isEmpty)
        #expect(try parse("https://pota.app/#/park/US-1234").records.isEmpty)
        #expect(try parse("").records.isEmpty)
    }

    // MARK: - Bounds

    @Test("editing a row that does not exist is refused, not fatal")
    func outOfRangeRowIsRefused() throws {
        let document = try parse("<CALL:5>W1ABC<EOR>\n")
        #expect(document.recordBySettingValue("X", forColumn: "CALL", inRecordAt: 7) == nil)
        #expect(document.recordBySettingValue("X", forColumn: "CALL", inRecordAt: -1) == nil)
    }
}
