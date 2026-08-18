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

    /// True when the file ended immediately after its last `<EOR>`, with no line break.
    ///
    /// A property of the file, deliberately, even though only one record can show it.
    /// Held on the record that happened to be last, it travelled with that record: sort
    /// the log and the empty separator landed in the middle, fusing two QSOs onto one
    /// line. §8's one-QSO-per-line convention exists so a line-oriented diff of two logs
    /// means something, and that is exactly what it stopped meaning.
    ///
    /// Set only for a file that keeps the convention in the first place. A log written
    /// entirely on one line has no separators to speak of and is left alone.
    public var endsWithoutFinalSeparator: Bool

    /// Non-fatal problems found while parsing. Empty for a well-formed file, and capped
    /// at `ADIFScanner.warningLimit` — see `suppressedWarnings`.
    public var warnings: [ADIFWarning]

    /// How many further warnings were found and not kept.
    ///
    /// A file that is not ADIF has a defect roughly every few bytes: 750 KB of an HTML
    /// error page — the shape §6.4 names as its own example — produced a hundred thousand
    /// warnings, an array nobody reads to the end of. The list is capped, and this counts
    /// what the cap dropped so the banner can still say how many problems there were.
    /// Reporting "and 99 others" when there were 100,000 would be worse than a long array.
    public var suppressedWarnings: Int

    public init(
        header: String? = nil,
        records: [ADIFRecord] = [],
        byteOrderMark: Bool = false,
        endsWithoutFinalSeparator: Bool = false,
        warnings: [ADIFWarning] = [],
        suppressedWarnings: Int = 0
    ) {
        self.header = header
        self.records = records
        self.byteOrderMark = byteOrderMark
        self.endsWithoutFinalSeparator = endsWithoutFinalSeparator
        self.warnings = warnings
        self.suppressedWarnings = suppressedWarnings
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

        /// A field's LENGTH was not a non-negative number at all — `<CALL:x>`, `<CALL:>`,
        /// `<CALL:-1>`. The field is kept and its value recovered by scanning to the next
        /// tag; `declared` is the spelling the file used, since there is no number.
        case unparseableLength(field: String, declared: String, recovered: Int)

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

        /// One record carried the same field name twice. Both copies survive the round
        /// trip, but only the first is visible anywhere in the app — see the scanner.
        case duplicateFieldInRecord(field: String)
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
