import Testing
import Foundation
@testable import ADIFKit

/// Semantic tests. The round-trip suite proves bytes survive; these prove the parser
/// understood them. Both matter — a parser that treated each file as one opaque blob
/// would sail through every round-trip test in the suite next door.
@Suite("Parser")
struct ParserTests {

    private func parse(_ text: String) throws -> ADIFDocument {
        try ADIFParser.parse(Data(text.utf8))
    }

    private func parseFixture(_ name: String) throws -> ADIFDocument {
        let url = Fixtures.all.first { $0.lastPathComponent == name }
        let found = try #require(url, "fixture \(name) is missing")
        return try ADIFParser.parse(Fixtures.data(found))
    }

    // MARK: - Structure

    @Test("header is detected and kept verbatim")
    func headerVerbatim() throws {
        let document = try parse("Some comment\n<ADIF_VER:5>3.1.6\n<EOH>\n<CALL:5>W1ABC<EOR>\n")
        #expect(document.header == "Some comment\n<ADIF_VER:5>3.1.6\n<EOH>\n")
        #expect(document.records.count == 1)
    }

    @Test("a file starting with a tag has no header, and does not gain one")
    func headerlessStaysHeaderless() throws {
        let document = try parseFixture("no-header.adi")
        #expect(document.header == nil)
        #expect(document.records.count == 2)

        let written = String(decoding: ADIFWriter.write(document), as: UTF8.self)
        #expect(!written.uppercased().contains("<EOH>"),
                "a headerless file must not acquire a header (decision 4)")
    }

    @Test("a file opening with <EOH> has an empty header, not no header")
    func emptyHeaderIsAHeader() throws {
        // §8's literal rule — first non-whitespace character is `<`, therefore no
        // header — gets this wrong and would read <EOH> as a record terminator.
        let document = try parseFixture("bare-eor.adi")
        #expect(document.header == "<EOH>\n")
        #expect(document.records.count == 3)
        #expect(document.records[0].fields.isEmpty)
        #expect(document.records[1].fields.count == 1)
        #expect(document.records[2].fields.isEmpty)
    }

    @Test("an empty file yields an empty document")
    func emptyFile() throws {
        let document = try parse("")
        #expect(document.header == nil)
        #expect(document.records.isEmpty)
        #expect(document.warnings.isEmpty)
    }

    // MARK: - Fields

    @Test("field name casing is preserved but lookup is case-insensitive")
    func casingPreservedLookupInsensitive() throws {
        let document = try parseFixture("mixed-case.adi")
        let first = document.records[0]

        #expect(first.fields[0].spelling == "call")
        #expect(first.fields[1].spelling == "QSL_RCVD")
        #expect(first.fields[0].name == "CALL")

        #expect(first["call"] == "W1ABC")
        #expect(first["CALL"] == "W1ABC")
        #expect(first["Call"] == "W1ABC")

        // Second record spells the same fields differently; they are still one column.
        #expect(document.records[1].fields[0].spelling == "Call")
        #expect(document.columnNames == ["CALL", "QSL_RCVD", "MODE"])
    }

    @Test("a zero-length field is present with an empty value")
    func zeroLengthFieldIsPresent() throws {
        let record = try parseFixture("zero-length-field.adi").records[0]

        // The distinction §9 collapsed and decision 2 restored.
        #expect(record["COMMENT"] == "")
        #expect(record.hasField("COMMENT"))
        #expect(record.isEmpty("COMMENT"))

        #expect(record["NOTES"] == nil)
        #expect(!record.hasField("NOTES"))
        #expect(record.isEmpty("NOTES"))
    }

    @Test("type indicators survive")
    func typeIndicators() throws {
        let record = try parseFixture("type-indicators.adi").records[0]
        #expect(record.fields[0].typeIndicator == "S")
        #expect(record.fields[1].typeIndicator == "D")
        #expect(record.fields[2].typeIndicator == "N")
        #expect(record["QSO_DATE"] == "20260101")
    }

    @Test("a value may contain '<' without confusing the scanner")
    func angleBracketInValue() throws {
        let record = try parseFixture("angle-bracket-in-value.adi").records[0]
        #expect(record["COMMENT"] == "rig <3 antenna")
        #expect(record["MODE"] == "FT8")
    }

    @Test("a value may contain newlines")
    func newlineInValue() throws {
        let record = try parseFixture("newline-in-value.adi").records[0]
        #expect(record["NOTES"] == "line one\nline two\nend")
        #expect(record["MODE"] == "FT8")
    }

    @Test("unknown, APP_, and USERDEF fields are kept")
    func unknownFieldsKept() throws {
        let document = try parseFixture("userdef-and-app.adi")
        let record = document.records[0]
        #expect(record["APP_UNKNOWN_THING"] == "hello")
        #expect(record["SWEATERSIZE"] == "M")
        #expect(record["NOT_A_REAL_FIELD"] == "xyz")

        // USERDEF declarations live in the header and are readable without being
        // re-serialized from a parsed form.
        let userdefs = document.headerFields.filter { $0.name.hasPrefix("USERDEF") }
        #expect(userdefs.count == 2)
        #expect(userdefs[0].value == "SweaterSize,{S,M,L}")
    }

    // MARK: - Columns

    @Test("columns are the union of all fields, in first-encountered order")
    func columnUnion() throws {
        let document = try parseFixture("sparse-fields.adi")
        #expect(document.columnNames == ["CALL", "RST_SENT", "MODE", "GRIDSQUARE"])
        #expect(document.records[1]["RST_SENT"] == nil)
    }

    @Test("records keep their own field order")
    func perRecordFieldOrder() throws {
        let document = try parseFixture("varying-field-order.adi")
        #expect(document.records[0].fields.map(\.name) == ["CALL", "MODE", "BAND"])
        #expect(document.records[1].fields.map(\.name) == ["BAND", "CALL", "MODE"])
        #expect(document.records[2].fields.map(\.name) == ["MODE", "BAND", "CALL"])
    }

    // MARK: - Recovery

    @Test("a length that is too short still recovers the whole value")
    func lengthTooShort() throws {
        let document = try parseFixture("bad-length-short.adi")
        #expect(document.records[0]["CALL"] == "W1ABC")
        #expect(document.records[0]["MODE"] == "FT8")
        #expect(document.warnings.count == 1)
    }

    @Test("a length that overruns does not swallow the following field")
    func lengthTooLong() throws {
        // The failure this guards against: resynchronizing from the end of the declared
        // length rather than the start of the value, which eats <MODE:3>FT8 entirely.
        let document = try parseFixture("bad-length-long.adi")
        #expect(document.records[0]["CALL"] == "W1ABC")
        #expect(document.records[0]["MODE"] == "FT8")
        #expect(document.records[0].fields.count == 2)
    }

    @Test("a byte-counted length on multibyte data is recognized")
    func lengthAsBytes() throws {
        let document = try parseFixture("length-as-bytes.adi")
        #expect(document.records[0]["COMMENT"] == "Grüße")
        #expect(document.records[0]["MODE"] == "FT8")

        let isByteWarning = document.warnings.contains {
            if case .lengthInterpretedAsBytes = $0.kind { return true }
            return false
        }
        #expect(isByteWarning, "expected the byte-count reading to be identified as such")
    }

    @Test("stray text between fields does not become part of the value")
    func textBetweenFields() throws {
        // An honest length landing on whitespace means the length was right and the
        // text is stray — as opposed to bad-length-short, where it lands mid-token.
        let document = try parseFixture("text-between-fields.adi")
        #expect(document.records[0]["CALL"] == "W1ABC")
        #expect(document.records[0]["MODE"] == "FT8")
    }

    @Test("a truncated final record is kept, not discarded")
    func truncatedRecordKept() throws {
        let document = try parseFixture("truncated.adi")
        #expect(document.records.count == 2)
        #expect(document.records[1]["CALL"] == "W2DEF")
        #expect(document.records[1].isTruncated)
    }

    @Test("a file ending mid-tag does not fabricate a tag on the way out")
    func truncatedTagDoesNotFuse() throws {
        // Regression: the leftover "<MOD" was written before the synthesized <EOR>,
        // and the two fused into a terminator literally named "MOD<EOR".
        let document = try parseFixture("truncated-tag.adi")
        let reparsed = try ADIFParser.parse(ADIFWriter.write(document))
        for record in reparsed.records {
            #expect(record.terminatorSpelling.uppercased() == "EOR",
                    "invented terminator \(record.terminatorSpelling)")
        }
    }

    @Test("warnings carry a byte offset")
    func warningsCarryOffsets() throws {
        let document = try parseFixture("bad-length-short.adi")
        let warning = try #require(document.warnings.first)
        #expect(warning.byteOffset > 0)
    }

    // MARK: - Encoding

    @Test("invalid UTF-8 refuses to open and names the byte")
    func invalidUTF8() {
        let bytes = Data([0x3C, 0x45, 0x4F, 0x48, 0x3E, 0x0A, 0xFF])
        #expect(throws: ADIFParseError.invalidUTF8(byteOffset: 6)) {
            try ADIFParser.parse(bytes)
        }
    }

    @Test("the fixture's invalid byte is located exactly")
    func invalidUTF8Offset() throws {
        let url = try #require(Fixtures.all.first { $0.lastPathComponent == "invalid-utf8.adi" })
        let data = try Fixtures.data(url)
        #expect(throws: ADIFParseError.invalidUTF8(byteOffset: 31)) {
            try ADIFParser.parse(data)
        }
    }

    @Test("overlong encodings and surrogates are rejected")
    func rejectsIllegalUTF8Forms() {
        // 0xC0 0x80 is an overlong encoding of NUL; ED A0 80 is a surrogate. Both
        // decode to plausible scalars and both are illegal.
        #expect(ADIFParser.firstInvalidUTF8Offset([0x41, 0xC0, 0x80]) == 1)
        #expect(ADIFParser.firstInvalidUTF8Offset([0x41, 0xED, 0xA0, 0x80]) == 1)
        #expect(ADIFParser.firstInvalidUTF8Offset([0x41, 0xC3, 0xA9]) == nil)
    }

    @Test("a BOM is preserved rather than stripped")
    func bomPreserved() throws {
        let document = try parseFixture("bom.adi")
        #expect(document.byteOrderMark)
        let written = ADIFWriter.write(document)
        #expect([UInt8](written).prefix(3) == [0xEF, 0xBB, 0xBF])
    }

    // MARK: - The real thing

    @Test("the FT8CN log parses exactly")
    func ft8cnFixture() throws {
        let document = try parseFixture("FT8CN6469053684847039306.txt")

        #expect(document.records.count == 66)
        #expect(document.header == "FT8CN ADIF Export<eoh>\n")
        #expect(document.warnings.isEmpty)

        // 16 fields on every record, 1056 in total.
        #expect(document.records.allSatisfy { $0.fields.count == 16 })

        let first = document.records[0]
        #expect(first["CALL"] == "W9AV")
        #expect(first["STATION_CALLSIGN"] == "WW8L")
        #expect(first["QSO_DATE"] == "20260209")
        #expect(first["COMMENT"] == "Distance: 1361 km, QSO by FT8CN")

        // Lowercase spellings and the single-space separators are what make this file
        // byte-identical on the way out.
        #expect(first.fields[0].spelling == "call")
        #expect(first.fields[1].spelling == "QSL_RCVD")
        #expect(first.fields.allSatisfy { $0.trailingText == " " })
        #expect(first.terminatorSpelling == "eor")

        // The whole point of the app: this field is what's missing.
        #expect(document.records.allSatisfy { !$0.hasField("MY_SIG_INFO") })
    }

    @Test("appending a field matches the record's existing separator style")
    func appendMatchesSeparators() throws {
        // Groundwork for the POTA stamp: an added field must not butt against <eor>.
        var record = try parseFixture("FT8CN6469053684847039306.txt").records[0]
        record.appendField(named: "MY_SIG_INFO", value: "US-1234")

        #expect(record.fields.last?.trailingText == " ")
        let rendered = ADIFWriter.write(ADIFDocument(records: [record]))
        let text = String(decoding: rendered, as: UTF8.self)
        #expect(text.contains("<MY_SIG_INFO:7>US-1234 <eor>"))
    }
}
