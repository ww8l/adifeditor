import Testing
import Foundation
@testable import ADIFKit

/// The §11 gate. Until every test in this file passes against every fixture, no UI
/// code gets written.
@Suite("Round trip")
struct RoundTripTests {

    /// The headline invariant: an unedited well-formed file comes back out byte for
    /// byte (CLAUDE.md §6.2a).
    @Test("unedited files are byte-identical",
          arguments: Fixtures.all.filter {
              !Fixtures.isByteIdentityExempt($0) && !Fixtures.isFatal($0)
          })
    func byteIdentical(_ url: URL) throws {
        let original = try Fixtures.data(url)
        let document = try ADIFParser.parse(original)
        let written = ADIFWriter.write(document)

        #expect(written == original,
                "\(url.lastPathComponent) did not survive the round trip byte for byte")
    }

    /// A well-formed file must parse silently. A warning on a clean file means the
    /// recovery ladder is firing when it shouldn't, which would go unnoticed otherwise.
    @Test("well-formed files parse without warnings",
          arguments: Fixtures.all.filter {
              !Fixtures.isExpectedToWarn($0) && !Fixtures.isFatal($0)
          })
    func wellFormedFilesAreSilent(_ url: URL) throws {
        let document = try ADIFParser.parse(Fixtures.data(url))
        #expect(document.warnings.isEmpty,
                "\(url.lastPathComponent) is well-formed but warned: \(document.warnings)")
    }

    /// §11's stated form: parse, write, parse again, and assert the two parses agree.
    /// Applies to every file that opens at all, malformed included.
    @Test("parse is stable across a write",
          arguments: Fixtures.all.filter { !Fixtures.isFatal($0) })
    func parseStability(_ url: URL) throws {
        let first = try ADIFParser.parse(Fixtures.data(url))
        let second = try ADIFParser.parse(ADIFWriter.write(first))

        // Compared on fields rather than whole records: `isTruncated` marks a defect
        // in the *input*, and the writer repairs it by supplying a terminator, so the
        // flag is legitimately clear the second time through.
        //
        // `lengthSpelling` is the same category and is set aside for the same reason. It
        // is how the *input* wrote LENGTH, and a wrong one is exactly what §6.2a's single
        // exception licenses the writer to correct — `<CALL:3>W1ABC` comes back as
        // `<CALL:5>`, so the spellings differ by design while the fields do not. The
        // byte-identity test next door is what holds the well-formed files to their
        // original spelling.
        #expect(first.records.map { $0.fields.map(withoutLengthSpelling) }
                    == second.records.map { $0.fields.map(withoutLengthSpelling) },
                "\(url.lastPathComponent): record fields differ")
        #expect(first.records.map(\.terminatorSpelling) == second.records.map(\.terminatorSpelling),
                "\(url.lastPathComponent): record terminators differ")
        #expect(first.header == second.header, "\(url.lastPathComponent): headers differ")
        #expect(first.byteOrderMark == second.byteOrderMark,
                "\(url.lastPathComponent): BOM differs")
    }

    private func withoutLengthSpelling(_ field: ADIFField) -> ADIFField {
        var copy = field
        copy.lengthSpelling = nil
        return copy
    }

    /// Writing is idempotent: once through the writer, the bytes stop moving. This is
    /// what replaces §11's undefined notion of "canonical form" (decision 1).
    @Test("writing is idempotent", arguments: Fixtures.all.filter { !Fixtures.isFatal($0) })
    func writerIdempotence(_ url: URL) throws {
        let once = ADIFWriter.write(try ADIFParser.parse(Fixtures.data(url)))
        let twice = ADIFWriter.write(try ADIFParser.parse(once))
        #expect(once == twice, "\(url.lastPathComponent): writer is not idempotent")
    }

    /// §11's bar: "no fixture, however malformed, may crash the parser or produce
    /// output that loses a field present in the input."
    @Test("no field is lost", arguments: Fixtures.all.filter { !Fixtures.isFatal($0) })
    func noFieldLost(_ url: URL) throws {
        let original = try ADIFParser.parse(Fixtures.data(url))
        let reparsed = try ADIFParser.parse(ADIFWriter.write(original))

        #expect(original.records.count == reparsed.records.count,
                "\(url.lastPathComponent): record count changed")

        for (index, record) in original.records.enumerated() {
            let before = record.fields.map(\.name)
            let after = reparsed.records[index].fields.map(\.name)
            #expect(before == after,
                    "\(url.lastPathComponent) record \(index): fields changed \(before) -> \(after)")
        }
    }

    /// Malformed input must still open. §6.4: a clear diagnostic, never a crash.
    @Test("malformed fixtures parse and warn",
          arguments: Fixtures.all.filter { Fixtures.isExpectedToWarn($0) })
    func malformedStillParses(_ url: URL) throws {
        let document = try ADIFParser.parse(Fixtures.data(url))
        #expect(!document.warnings.isEmpty,
                "\(url.lastPathComponent) is malformed but produced no warning")
        for warning in document.warnings {
            #expect(warning.byteOffset >= 0)
        }
    }

    /// The single fatal case (decision 6).
    @Test("invalid UTF-8 refuses to open, with an offset",
          arguments: Fixtures.all.filter { Fixtures.isFatal($0) })
    func invalidUTF8IsFatal(_ url: URL) throws {
        #expect(throws: ADIFParseError.self) {
            try ADIFParser.parse(Fixtures.data(url))
        }
    }

    /// A corpus this small is easy to accidentally empty; if the glob breaks, every
    /// test above silently passes zero cases.
    @Test("the corpus is actually present")
    func corpusIsNotEmpty() {
        #expect(Fixtures.real.count >= 1, "no real logger fixtures found")
        #expect(Fixtures.synthetic.count >= 20, "synthetic corpus looks incomplete")
    }
}
