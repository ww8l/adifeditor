import Foundation

/// A parsed ADIF file: an optional header and an ordered list of records.
public struct ADIFDocument: Equatable, Sendable {
    /// Everything up to and including `<EOH>`, verbatim, plus any text following it
    /// before the first record. `nil` when the file began with `<` and therefore has no
    /// header (§8) — a distinction the writer preserves rather than papering over
    /// (decision 4).
    ///
    /// Held as raw text rather than parsed fields because §6.2 requires header comment
    /// text to survive, and a parse/re-emit cycle is exactly where such text gets lost.
    /// `headerFields` offers a read-only view for the few things that need one.
    public var header: String?

    public var records: [ADIFRecord]

    /// A UTF-8 BOM, if the file opened with one. Preserved, not stripped (decision 4).
    public var byteOrderMark: Bool

    /// Non-fatal problems found while parsing. Empty for a well-formed file.
    public var warnings: [ADIFWarning]

    public init(
        header: String? = nil,
        records: [ADIFRecord] = [],
        byteOrderMark: Bool = false,
        warnings: [ADIFWarning] = []
    ) {
        self.header = header
        self.records = records
        self.byteOrderMark = byteOrderMark
        self.warnings = warnings
    }

    /// The union of every field name present anywhere in the file, in the order first
    /// encountered (§9). This is the grid's column set.
    ///
    /// Returns normalized (uppercase) names — the column identity — not spellings,
    /// since one column may be spelled `call` on one record and `CALL` on the next.
    public var columnNames: [String] {
        var seen = Set<String>()
        var order: [String] = []
        for record in records {
            for field in record.fields where seen.insert(field.name).inserted {
                order.append(field.name)
            }
        }
        return order
    }

    /// The header's fields, parsed on demand for callers that need to read `USERDEF`
    /// declarations or `PROGRAMID`. Read-only by construction: the authority for what
    /// gets written is always `header`, the raw text.
    public var headerFields: [ADIFField] {
        guard let header else { return [] }
        var scanner = ADIFScanner(text: header)
        return scanner.scanFieldsToTerminator().fields
    }
}

/// A non-fatal problem found while parsing. The file still opened; something in it was
/// irregular and the parser recovered.
///
/// §6.4 requires a diagnostic that names the problem and its offset rather than a stack
/// trace, and these are what the validation panel surfaces.
public struct ADIFWarning: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// A field's declared LENGTH did not match its data when read as characters,
        /// but did when read as UTF-8 bytes. The §8 hazard, recovered.
        case lengthInterpretedAsBytes(field: String, declared: Int, actual: Int)

        /// A field's declared LENGTH matched neither reading. The value was recovered
        /// by scanning to the next tag.
        case lengthMismatch(field: String, declared: Int, recovered: Int)

        /// Text sat between two fields. §8 says it belongs to neither; it is carried
        /// through to the output but flagged here in case it signals a deeper problem.
        case unexpectedTextBetweenFields(text: String)

        /// Nothing parseable was found where a tag was expected; the parser scanned
        /// forward to the next plausible tag.
        case resynchronized(skipped: Int)

        /// The file ended before the final record's `<EOR>`. The partial record is kept.
        case truncatedFinalRecord(fieldCount: Int)

        /// The file ended in the middle of a tag.
        case truncatedTag(partial: String)
    }

    public var kind: Kind

    /// Byte offset into the original file, for the diagnostic §6.4 asks for.
    public var byteOffset: Int

    public init(kind: Kind, byteOffset: Int) {
        self.kind = kind
        self.byteOffset = byteOffset
    }
}

/// The one condition that refuses to open a file (decision 6).
public enum ADIFParseError: Error, Equatable, Sendable {
    /// The bytes are not valid UTF-8. Decoding leniently would substitute replacement
    /// characters and silently alter the user's data, which 6.2a forbids, so this fails
    /// loudly instead.
    case invalidUTF8(byteOffset: Int)
}

extension ADIFParseError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .invalidUTF8(let byteOffset):
            return "The file is not valid UTF-8 text. The first invalid byte is at "
                 + "offset \(byteOffset)."
        }
    }
}
