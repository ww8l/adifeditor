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

    @Test("columns are the union of all fields, merged into one order")
    func columnUnion() throws {
        let document = try parseFixture("sparse-fields.adi")

        // GRIDSQUARE appears only on the third record, between RST_SENT and MODE, and
        // that is where it belongs in the grid — not tacked onto the end merely because
        // the earlier records had no opinion about it (decision 14).
        #expect(document.columnNames == ["CALL", "RST_SENT", "GRIDSQUARE", "MODE"])
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

    @Test("a LENGTH that is not a number keeps the field rather than dropping it")
    func unparseableLengthKeepsField() throws {
        // Before this was handled, <CALL:x> made the whole tag unparseable, the scanner
        // resynchronized past it, and the operator was left looking at a QSO with no
        // callsign — invisible to dedupe, to Find and to QRZ. The bytes still round-
        // tripped, so the byte-identity suite next door had nothing to say about it.
        let document = try parseFixture("unparseable-length.adi")
        #expect(document.records.count == 1)
        #expect(document.records[0].fields.map(\.spelling) == ["CALL", "MODE"])
        #expect(document.records[0]["CALL"] == "W1ABC")
        #expect(document.records[0]["MODE"] == "FT8")

        let kinds = document.warnings.map(\.kind)
        #expect(kinds == [.unparseableLength(field: "CALL", declared: "x", recovered: 5)])
    }

    @Test("a LENGTH too large to address the file recovers instead of trapping")
    func hugeLengthDoesNotOverflow() throws {
        // §6.4: `min(valueStart + declared, scalars.count)` traps on overflow, and the
        // process died on SIGTRAP with no alert and no chance to save anything else.
        // A header field triggered it too, so the app could die before a window existed.
        let document = try parseFixture("huge-length.adi")
        #expect(document.records.count == 2)
        #expect(document.records[1]["CALL"] == "W2DEF")
        #expect(document.records[1]["MODE"] == "FT8")

        let kinds = document.warnings.map(\.kind)
        #expect(kinds == [.lengthMismatch(field: "CALL",
                                          declared: Int.max,
                                          recovered: 5)])
    }

    @Test("a header field's huge LENGTH does not trap either")
    func hugeLengthInHeader() throws {
        let document = try parse("<PROGRAMID:\(Int.max)>x<EOH>\n<CALL:5>W1ABC<EOR>\n")
        #expect(document.records.count == 1)
        #expect(document.records[0]["CALL"] == "W1ABC")
    }

    @Test("a stray < does not become part of the next field's name")
    func strayBracketDoesNotRenameTheNextField() throws {
        // `<<MODE:3>FT8` used to parse as a field literally named "<MODE", because the
        // scan for the closing `>` ran straight past the second `<`. The result looked
        // well-formed, so no warning fired at all and a bogus column reached the grid.
        let document = try parseFixture("stray-bracket.adi")
        #expect(document.records[0].fields.map(\.spelling) == ["CALL", "MODE"])
        #expect(document.records[0]["MODE"] == "FT8")
        #expect(document.warnings.map(\.kind) == [.resynchronized(skipped: 1)])
    }

    @Test("an HTML error page opens without inventing columns out of markup")
    func htmlErrorPageInventsNoFields() throws {
        // §6.4's own example: a failed log download is an HTML page, not ADIF. Recovery
        // must not be so eager that `<a href="http://example.com/retry">` becomes a
        // field named `a href="http`. Nothing here is a field, so nothing is a column.
        let document = try parseFixture("html-error-page.adi")
        #expect(document.columnNames.isEmpty)
        #expect(document.records.allSatisfy { $0.fields.isEmpty })
        #expect(!document.warnings.isEmpty)
    }

    @Test("a well-formed tag with an odd name is still a field")
    func oddFieldNameStillParses() throws {
        // The plausible-name rule gates only the broken-LENGTH recovery. A logger that
        // emits a hyphen in a field name, with an honest length, must not lose the field.
        let document = try parse("<EOH>\n<MY-FIELD:3>abc<CALL:5>W1ABC<EOR>\n")
        #expect(document.records[0].fields.map(\.spelling) == ["MY-FIELD", "CALL"])
        #expect(document.warnings.isEmpty)
    }

    @Test("resynchronization is linear, not quadratic")
    func resyncIsLinear() throws {
        // Every `<` that opened nothing used to materialize the entire rest of the file
        // as a String to search it for `>`, then advance one character. 80 KB took 21
        // seconds with no progress bar and no way to cancel. The shape of the bug is
        // what this asserts: 4x the input must not cost anywhere near 16x the time.
        func parseTime(_ count: Int) throws -> TimeInterval {
            let text = "<EOH>\n" + String(repeating: "<>", count: count)
                     + "<CALL:5>W1ABC<EOR>\n"
            let data = Data(text.utf8)
            let started = Date()
            _ = try ADIFParser.parse(data)
            return -started.timeIntervalSinceNow
        }

        _ = try parseTime(2_000)                       // warm up, unmeasured
        let small = try parseTime(10_000)
        let large = try parseTime(40_000)

        // Quadratic would be ~16x. A generous ceiling: the point is the exponent, and a
        // loaded CI runner must not be able to fail this for being slow.
        #expect(large < max(small * 8, 0.5),
                "40k took \(large)s against 10k's \(small)s — the quadratic scan is back")
    }

    @Test("a tag's own spelling of LENGTH and TYPE survives the round trip")
    func oddTagSpellingsSurvive() throws {
        // §6.2a lets an unedited file's bytes move only at the site of a recovered parse
        // error, and requires a warning there. All five of these parsed silently and came
        // back different: `005`→`5`, `+5`→`5`, `DATE`→`D`, `S:X`→`S`, `5:`→`5`. Nothing
        // was wrong with the file, so there was nothing to warn about and no banner — the
        // user edited nothing, pressed Save, and got a different file.
        let name = "odd-tag-spellings.adi"
        let url = try #require(Fixtures.all.first { $0.lastPathComponent == name })
        let data = try Fixtures.data(url)

        let document = try ADIFParser.parse(data)
        #expect(document.warnings.isEmpty)
        #expect(ADIFWriter.write(document) == data)

        let fields = document.records[0].fields
        #expect(fields.map(\.lengthSpelling) == ["005", "8", "3", "3", "+3"])
        #expect(fields.map(\.typeSpelling) == [nil, "DATE", "S:X", "", nil])
        #expect(fields.map(\.typeIndicator) == [nil, "D", "S", nil, nil])
    }

    @Test("an edited cell gets a freshly counted length, not the file's old spelling")
    func editedCellRecountsLength() throws {
        // The other half of the rule: `lengthSpelling` is preserved only while it still
        // describes the value. Re-emitting `005` over a six-character value would be
        // writing a length known to be wrong.
        var document = try parse("<EOH>\n<CALL:005>W1ABC<EOR>\n")
        let edited = try #require(document.recordBySettingValue("W1ABCD",
                                                                forColumn: "CALL",
                                                                inRecordAt: 0))
        document.records[0] = edited
        #expect(String(decoding: ADIFWriter.write(document), as: UTF8.self)
                    == "<EOH>\n<CALL:6>W1ABCD<EOR>\n")
    }

    @Test("warnings carry a byte offset")
    func warningsCarryOffsets() throws {
        let document = try parseFixture("bad-length-short.adi")
        let warning = try #require(document.warnings.first)
        #expect(warning.byteOffset > 0)
    }

    @Test("the offset counts bytes, not characters")
    func offsetsCountBytes() throws {
        // `<EOH>\n<CALL:5>W1ABC<COMMENT:7>Grüße<MODE:3>FT8<EOR>\n`, where the ü and ß
        // are two bytes each. The warning belongs at the start of COMMENT's value: 6 for
        // the header line, 8 for `<CALL:5>`, 5 for the callsign, 11 for `<COMMENT:7>`.
        // Counting scalars instead of bytes gives the same answer here and a wrong one
        // for anything after the multibyte data — which is why the second case exists.
        let document = try parseFixture("length-as-bytes.adi")
        let warning = try #require(document.warnings.first)
        #expect(warning.byteOffset == 30)
    }

    @Test("an offset after multibyte data counts the multibyte bytes")
    func offsetsAfterMultibyteContent() throws {
        // Grüße is 5 characters and 7 bytes, so a scalar count would report 31 and point
        // two bytes short — inside `<CALL`. §6.4 wants the offset to name the defect.
        let text = "<EOH>\n<COMMENT:5>Grüße <CALL:3>W1ABC<EOR>\n"
        let document = try ADIFParser.parse(Data(text.utf8))
        let warning = try #require(document.warnings.first)
        #expect(warning.kind == .lengthMismatch(field: "CALL", declared: 3, recovered: 5))
        #expect(warning.byteOffset == 33)
    }

    @Test("a BOM is counted in the offsets that follow it")
    func offsetsIncludeTheBOM() throws {
        // The BOM is taken off the front before scanning (decision 4 keeps it as a flag),
        // and used to drop out of the count with it, so every warning in a BOM file
        // pointed three bytes early.
        var bytes = Data([0xEF, 0xBB, 0xBF])
        bytes.append(contentsOf: Data("Test header\n<EOH>\n<CALL:3>W1ABC<EOR>\n".utf8))
        let document = try ADIFParser.parse(bytes)
        let warning = try #require(document.warnings.first)
        // 3 for the BOM, 12 for the header line, 6 for <EOH>\n, 8 for <CALL:3>.
        #expect(warning.byteOffset == 29)
    }

    @Test("a preamble is counted in the offsets that follow it")
    func offsetsIncludeThePreamble() throws {
        // A headerless file with leading text gets a fresh scanner over the text from the
        // first `<`, whose offsets used to be relative to that `<`. On a real file that
        // lands the reported offset inside a valid field, which is worse than none.
        let text = "some preamble text 12345\n<CALL:3>W1ABC<EOR>\n"
        let document = try ADIFParser.parse(Data(text.utf8))
        let warning = try #require(document.warnings.first)
        // 25 for the preamble, 8 for <CALL:3>.
        #expect(warning.byteOffset == 33)
    }

    // MARK: - Separators and stray tags

    @Test("a separator between fields is not part of the value")
    func separatorBetweenFields() throws {
        // A logger writing `<CALL:5>W1ABC,<GRIDSQUARE:4>DN70,` declares honest lengths
        // and puts its own separator between fields. §8 says text between fields is
        // ignored; the length is right and must be kept. This used to override every one
        // of those lengths and glue the comma onto the value, so the file was written
        // back as `<CALL:6>W1ABC,` — bytes changed on a file nobody edited (§6.2a), with
        // a warning naming a fault that did not exist.
        let document = try parseFixture("separator-between-fields.adi")
        #expect(document.records.count == 1)
        #expect(document.records[0]["CALL"] == "W1ABC")
        #expect(document.records[0]["GRIDSQUARE"] == "DN70")
        #expect(document.records[0]["MODE"] == "FT8")
        #expect(document.records[0].fields.map(\.lengthSpelling) == ["5", "4", "3"])
        #expect(document.warnings.map(\.kind) == [
            .unexpectedTextBetweenFields(text: ","),
            .unexpectedTextBetweenFields(text: ","),
        ])
    }

    @Test("a run that looks like data is still treated as a wrong length")
    func dataAfterTheLengthIsNotASeparator() throws {
        // The other half of the rule above, and the reason it is not simply "a tag
        // follows the run": `<CALL:3>W1ABC<MODE:3>FT8` also has a well-formed tag after
        // its run, and there the run is the rest of the callsign.
        let document = try parseFixture("bad-length-short.adi")
        #expect(document.records[0]["CALL"] == "W1ABC")
        #expect(document.warnings.map(\.kind)
                == [.lengthMismatch(field: "CALL", declared: 3, recovered: 5)])
    }

    @Test("a stray tag inside a record does not end the record")
    func strayTagIsNotATerminator() throws {
        // ADIF has two terminators. Any other tag without a LENGTH used to be taken for
        // one, so `<COMMENT:3>a<b>c <CALL:5>W1ABC<EOR>` produced two QSOs from one
        // `<EOR>` — the grid showing a contact the file does not contain.
        let document = try parseFixture("tag-inside-value.adi")
        #expect(document.records.count == 1)
        #expect(document.records[0]["CALL"] == "W1ABC")
        #expect(document.warnings.contains { $0.kind == .unexpectedTextBetweenFields(text: "<b>") })
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
