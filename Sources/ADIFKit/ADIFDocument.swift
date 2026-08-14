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

    /// The union of every field name present anywhere in the file, ordered by merging
    /// the records' own field orders (§9, as amended by decision 14). This is the grid's
    /// column set.
    ///
    /// Returns normalized (uppercase) names — the column identity — not spellings,
    /// since one column may be spelled `call` on one record and `CALL` on the next.
    ///
    /// §9's original rule was "the order first encountered", walking records start to
    /// finish and appending each new name. That makes the whole column layout hostage to
    /// the first record: clear one cell in row 1 and its field is no longer encountered
    /// until row 2, by which point every other field of row 1 is already in the list, so
    /// the column jumps to the far right of the grid. Deleting a value is not supposed to
    /// rearrange the spreadsheet.
    ///
    /// The rule instead is that a new field takes the place it holds in the first record
    /// that carries it — immediately after whichever known field precedes it there.
    /// Columns already placed are never moved, so the layout is stable no matter how much
    /// the records disagree with each other about field order.
    public var columnNames: [String] {
        var order: [String] = []
        var positions: [String: Int] = [:]

        for record in records {
            // Where in `order` this record's previous field sits. A field whose
            // predecessor is unknown anchors at -1 and lands at the front, which is what
            // a record that opens with a never-before-seen field should do.
            var anchor = -1

            for field in record.fields {
                if let known = positions[field.name] {
                    anchor = known
                    continue
                }

                let insertionPoint = anchor + 1
                order.insert(field.name, at: insertionPoint)
                // Everything at or after the insertion point shifted right by one.
                for index in insertionPoint..<order.count {
                    positions[order[index]] = index
                }
                anchor = insertionPoint
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
