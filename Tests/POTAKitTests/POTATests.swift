import Testing
import Foundation
@testable import POTAKit
import ADIFKit

@Suite("Park references")
struct ParkReferenceTests {

    @Test("well-formed references are recognized", arguments: [
        "US-1234", "VE-5093", "US-12345", "K-0001", "3B8-0001"
    ])
    func wellFormed(text: String) {
        #expect(ParkReference(text).isWellFormed)
    }

    @Test("malformed references are flagged but still usable", arguments: [
        "US1234", "US-12", "US-123456", "-1234", "US-", "hello", "US-12A4"
    ])
    func malformed(text: String) {
        let park = ParkReference(text)
        #expect(!park.isWellFormed)

        // Lenient (§10.2): flagged, never refused. The text survives exactly as typed.
        #expect(park.text == text)
    }

    @Test("references are split on commas, spaces and newlines")
    func listSeparators() {
        #expect(ParkReference.list(from: "US-1234, US-5678").map(\.text) == ["US-1234", "US-5678"])
        #expect(ParkReference.list(from: "US-1234 US-5678").map(\.text) == ["US-1234", "US-5678"])
        #expect(ParkReference.list(from: "US-1234\nUS-5678").map(\.text) == ["US-1234", "US-5678"])
    }

    @Test("duplicate references are dropped, keeping the first")
    func listDeduplicates() {
        // Stamping the same park twice would write the same file twice.
        #expect(ParkReference.list(from: "US-1234, us-1234").map(\.text) == ["US-1234"])
    }

    @Test("empty input yields no references")
    func listEmpty() {
        #expect(ParkReference.list(from: "").isEmpty)
        #expect(ParkReference.list(from: "  ,  ").isEmpty)
    }
}

@Suite("Stamp")
struct StampTests {

    private func parse(_ text: String) throws -> ADIFDocument {
        try ADIFParser.parse(Data(text.utf8))
    }

    private func text(_ document: ADIFDocument) -> String {
        String(decoding: ADIFWriter.write(document), as: UTF8.self)
    }

    @Test("stamping fills every QSO that has no reference")
    func stampFillsEmpty() throws {
        let document = try parse("""
            <CALL:5>W1ABC <EOR>
            <CALL:5>K2XYZ <EOR>

            """)
        let outcome = POTAStamp.stamp(document, with: ParkReference("US-1234"))

        #expect(outcome.filled == 2)
        #expect(outcome.preserved == 0)
        #expect(outcome.document.records.allSatisfy { $0["MY_SIG_INFO"] == "US-1234" })
    }

    @Test("stamping never overwrites a reference that is already there")
    func stampPreservesExisting() throws {
        // §6.3. Including — especially — one that disagrees with the park being stamped:
        // the operator put it there and only the operator should change it.
        let document = try parse("""
            <CALL:5>W1ABC <MY_SIG_INFO:7>US-9999 <EOR>
            <CALL:5>K2XYZ <EOR>

            """)
        let outcome = POTAStamp.stamp(document, with: ParkReference("US-1234"))

        #expect(outcome.filled == 1)
        #expect(outcome.preserved == 1)
        #expect(outcome.document.records[0]["MY_SIG_INFO"] == "US-9999")
        #expect(outcome.document.records[1]["MY_SIG_INFO"] == "US-1234")
    }

    @Test("a present but empty reference field counts as empty and gets filled")
    func stampFillsZeroLengthField() throws {
        let document = try parse("<CALL:5>W1ABC <MY_SIG_INFO:0> <EOR>\n")
        let outcome = POTAStamp.stamp(document, with: ParkReference("US-1234"))

        #expect(outcome.filled == 1)
        #expect(outcome.document.records[0]["MY_SIG_INFO"] == "US-1234")
    }

    @Test("stamping does not modify the document it was given")
    func stampLeavesSourceAlone() throws {
        let document = try parse("<CALL:5>W1ABC <EOR>\n")
        _ = POTAStamp.stamp(document, with: ParkReference("US-1234"))

        #expect(document.records[0]["MY_SIG_INFO"] == nil, "§6.1")
    }

    @Test("the stamped field takes the file's own spelling and position")
    func stampFollowsTheFilesConventions() throws {
        let document = try parse("""
            <call:5>W1ABC <my_sig_info:7>US-9999 <mode:3>FT8 <eor>
            <call:5>K2XYZ <mode:3>FT8 <eor>

            """)
        let outcome = POTAStamp.stamp(document, with: ParkReference("US-1234"))

        #expect(text(outcome.document).contains("<call:5>K2XYZ <my_sig_info:7>US-1234 <mode:3>FT8 <eor>"),
                "decisions 3 and 14: lower case, and in the place the other record keeps it")
    }

    @Test("MY_SIG is written only when asked for")
    func programFieldIsOptional() throws {
        let document = try parse("<CALL:5>W1ABC <EOR>\n")

        let without = POTAStamp.stamp(document, with: ParkReference("US-1234"))
        #expect(without.document.records[0]["MY_SIG"] == nil, "default off (§10.2)")

        let with = POTAStamp.stamp(document,
                                   with: ParkReference("US-1234"),
                                   alsoWriteProgramField: true)
        #expect(with.document.records[0]["MY_SIG"] == "POTA")
    }

    @Test("stamping loses nothing else in the file")
    func stampPreservesTheRest() throws {
        let source = """
            <ADIF_VER:5>3.1.6
            <EOH>
            <call:5>W1ABC <comment:0> <APP_FT8CN_X:3>abc <eor>

            """
        let document = try parse(source)
        let outcome = POTAStamp.stamp(document, with: ParkReference("US-1234"))
        let written = text(outcome.document)

        #expect(written.hasPrefix("<ADIF_VER:5>3.1.6\n<EOH>\n"), "header survives")
        #expect(written.contains("<comment:0>"), "zero-length field survives")
        #expect(written.contains("<APP_FT8CN_X:3>abc"), "vendor field survives")
    }
}

@Suite("Split")
struct SplitTests {

    private func parse(_ text: String) throws -> ADIFDocument {
        try ADIFParser.parse(Data(text.utf8))
    }

    @Test("every QSO appears in every park's file")
    func splitRepeatsEveryQSO() throws {
        let document = try parse("""
            <CALL:5>W1ABC <EOR>
            <CALL:5>K2XYZ <EOR>

            """)
        let parks = [ParkReference("US-1234"), ParkReference("US-5678")]
        let outputs = POTAStamp.split(document, into: parks, replacingExistingReferences: false)

        #expect(outputs.count == 2)
        for output in outputs {
            #expect(output.document.records.count == 2, "being in two parks counts for both")
            #expect(output.document.records.allSatisfy { $0["MY_SIG_INFO"] == output.park.text })
        }
    }

    @Test("the files differ only in the park reference")
    func splitFilesDifferOnlyByReference() throws {
        let document = try parse("<CALL:5>W1ABC <BAND:3>20M <EOR>\n")
        let outputs = POTAStamp.split(document,
                                      into: [ParkReference("US-1234"), ParkReference("US-5678")],
                                      replacingExistingReferences: false)

        let stripped = outputs.map { output in
            output.document.records.map { record in
                record.fields.filter { $0.name != "MY_SIG_INFO" }
            }
        }
        #expect(stripped[0] == stripped[1])
    }

    @Test("existing references are kept unless replacing was asked for")
    func splitRespectsExistingByDefault() throws {
        let document = try parse("""
            <CALL:5>W1ABC <MY_SIG_INFO:7>US-9999 <EOR>
            <CALL:5>K2XYZ <EOR>

            """)
        #expect(POTAStamp.recordsWithExistingReference(in: document) == 1)

        let kept = POTAStamp.split(document,
                                   into: [ParkReference("US-1234")],
                                   replacingExistingReferences: false)
        #expect(kept[0].document.records[0]["MY_SIG_INFO"] == "US-9999")

        let replaced = POTAStamp.split(document,
                                       into: [ParkReference("US-1234")],
                                       replacingExistingReferences: true)
        #expect(replaced[0].document.records[0]["MY_SIG_INFO"] == "US-1234")
        #expect(replaced[0].document.records[1]["MY_SIG_INFO"] == "US-1234")
    }

    @Test("splitting does not modify the source document")
    func splitLeavesSourceAlone() throws {
        let document = try parse("<CALL:5>W1ABC <EOR>\n")
        _ = POTAStamp.split(document,
                            into: [ParkReference("US-1234"), ParkReference("US-5678")],
                            replacingExistingReferences: true)

        #expect(document.records[0]["MY_SIG_INFO"] == nil, "§6.1: the source is untouched")
    }
}

@Suite("Filenames")
struct FilenameTests {

    private func parse(_ text: String) throws -> ADIFDocument {
        try ADIFParser.parse(Data(text.utf8))
    }

    @Test("the convention from the spec")
    func conventional() {
        #expect(POTAFilename.name(callsign: "W1XYZ",
                                  park: ParkReference("US-1234"),
                                  date: "20260811") == "W1XYZ@US-1234 20260811.adi")
    }

    @Test("a portable callsign does not become a path")
    func portableCallsign() {
        #expect(POTAFilename.name(callsign: "WW8L/P",
                                  park: ParkReference("US-1234"),
                                  date: "20260811") == "WW8L-P@US-1234 20260811.adi")
    }

    @Test("no date means no date, not a made-up one")
    func missingDate() {
        #expect(POTAFilename.name(callsign: "WW8L",
                                  park: ParkReference("US-1234"),
                                  date: "") == "WW8L@US-1234.adi")
    }

    @Test("callsign comes from STATION_CALLSIGN, falling back to OPERATOR")
    func callsignSource() throws {
        let station = try parse("<CALL:5>W1ABC <STATION_CALLSIGN:4>WW8L <OPERATOR:4>K2ZZ <EOR>\n")
        #expect(POTAFilename.callsign(in: station) == "WW8L")

        let operatorOnly = try parse("<CALL:5>W1ABC <OPERATOR:4>K2ZZ <EOR>\n")
        #expect(POTAFilename.callsign(in: operatorOnly) == "K2ZZ")

        let neither = try parse("<CALL:5>W1ABC <EOR>\n")
        #expect(POTAFilename.callsign(in: neither) == nil, "the interface has to ask")
    }

    @Test("the date is the earliest QSO_DATE in the log")
    func earliestDate() throws {
        let document = try parse("""
            <CALL:5>W1ABC <QSO_DATE:8>20260213 <EOR>
            <CALL:5>K2XYZ <QSO_DATE:8>20260209 <EOR>
            <CALL:5>W3GHI <QSO_DATE:8>20260401 <EOR>

            """)
        // No inference and no prompt for a log spanning days: the operator trims first
        // (decision 12).
        #expect(POTAFilename.earliestDate(in: document) == "20260209")
    }

    @Test("a log with no dates yields no date")
    func noDates() throws {
        #expect(POTAFilename.earliestDate(in: try parse("<CALL:5>W1ABC <EOR>\n")) == "")
    }
}
