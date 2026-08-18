import Foundation

/// Parses ADI bytes into an `ADIFDocument`.
///
/// The only failure mode is invalid UTF-8 (decision 6). Everything else — wrong
/// lengths, stray text, truncation, tags that make no sense — is recovered and recorded
/// as a warning, because §6.4 requires that a malformed file produce a diagnostic
/// rather than a refusal or a mangled log.
public enum ADIFParser {

    public static func parse(_ data: Data) throws -> ADIFDocument {
        let bytes = [UInt8](data)

        // Strict decode. Lenient decoding would substitute U+FFFD and silently alter
        // the user's bytes, which 6.2a forbids.
        if let offset = firstInvalidUTF8Offset(bytes) {
            throw ADIFParseError.invalidUTF8(byteOffset: offset)
        }

        var text = String(decoding: bytes, as: UTF8.self)

        // A BOM is preserved as a flag and written back (decision 4), not stripped from
        // the file and forgotten.
        var byteOrderMark = false
        if text.unicodeScalars.first == "\u{FEFF}" {
            byteOrderMark = true
            text.unicodeScalars.removeFirst()
        }

        guard !text.isEmpty else {
            return ADIFDocument(header: nil, records: [], byteOrderMark: byteOrderMark)
        }

        var document = ADIFDocument(byteOrderMark: byteOrderMark)

        // Decide whether the file has a header by scanning to the first terminator tag
        // and seeing which one it is.
        //
        // §8's stated rule — "if the first non-whitespace character is `<`, there is no
        // header" — misclassifies a file that opens directly with `<EOH>`, which is a
        // file with an empty header, not a headerless one. Several fixtures do exactly
        // that. Looking at the terminator handles both shapes correctly.
        var probe = ADIFScanner(text: text)
        let first = probe.scanFieldsToTerminator()
        let firstIsHeader = first.terminatorSpelling.map {
            ADIFField.normalize($0) == "EOH"
        } ?? false

        var scanner = ADIFScanner(text: text)
        if firstIsHeader {
            // Re-scan so the header's own text is captured verbatim, including any
            // comment text and the terminator's trailing newline.
            let headerResult = scanner.scanFieldsToTerminator()
            document.header = renderHeader(headerResult)
            document.warnings.append(contentsOf: scanner.warnings)
            scanner.warnings.removeAll()
        } else if let firstTag = text.firstIndex(of: "<") {
            // No `<EOH>`. Anything before the first tag is still bytes in the user's
            // file — carry it as header text so it survives the round trip.
            let preamble = String(text[text.startIndex..<firstTag])
            document.header = preamble.isEmpty ? nil : preamble
            scanner = ADIFScanner(text: String(text[firstTag...]))
        } else {
            // No tags at all: the whole file is preamble.
            document.header = text
            return document
        }

        while !scanner.isAtEnd {
            let result = scanner.scanFieldsToTerminator()
            if result.isEmpty && result.leadingText.isEmpty { break }

            // Stray text before a record's first field has nowhere structural to live;
            // attach it to the previous record's trailing text so the bytes survive.
            if !result.leadingText.isEmpty {
                if document.records.isEmpty {
                    document.header = (document.header ?? "") + result.leadingText
                } else {
                    document.records[document.records.count - 1].trailingText
                        += result.leadingText
                }
            }

            if result.isEmpty { continue }

            document.records.append(
                ADIFRecord(fields: result.fields,
                           terminatorSpelling: result.terminatorSpelling ?? "EOR",
                           trailingText: result.trailingText,
                           isTruncated: result.terminatorSpelling == nil)
            )
        }

        document.warnings.append(contentsOf: scanner.warnings)
        liftFinalSeparator(&document)
        return document
    }

    /// Moves "the file ends without a line break" off the last record and onto the
    /// document, giving that record the separator every other record uses.
    ///
    /// Without this the fact is stored on whichever record is last, and a sort carries it
    /// into the middle of the file — see `ADIFDocument.endsWithoutFinalSeparator`.
    ///
    /// Does nothing unless some other record actually has a separator. A log written
    /// entirely on one line never kept the convention, so there is nothing to restore and
    /// inventing a line break would rewrite bytes nobody edited (§6.2a).
    private static func liftFinalSeparator(_ document: inout ADIFDocument) {
        guard let last = document.records.last, last.trailingText.isEmpty else { return }

        var separator: String?
        for record in document.records.dropLast() where !record.trailingText.isEmpty {
            separator = record.trailingText.contains("\r\n") ? "\r\n" : "\n"
            break
        }
        guard let separator else { return }

        document.records[document.records.count - 1].trailingText = separator
        document.endsWithoutFinalSeparator = true
    }

    /// Reassembles the header's verbatim text from a scan result.
    private static func renderHeader(_ result: ADIFScanner.ScanResult) -> String {
        var out = result.leadingText
        for field in result.fields {
            out += ADIFWriter.render(field)
            out += field.trailingText
        }
        if let terminator = result.terminatorSpelling {
            out += "<\(terminator)>"
        }
        out += result.trailingText
        return out
    }

    // MARK: - UTF-8 validation

    /// Byte offset of the first invalid UTF-8 sequence, or `nil` if the input is valid.
    ///
    /// Written out rather than using `String(validating:)` because §6.4 asks for the
    /// *offset*, and the standard decoders only report pass or fail.
    static func firstInvalidUTF8Offset(_ bytes: [UInt8]) -> Int? {
        var i = 0
        let count = bytes.count
        while i < count {
            let byte = bytes[i]
            let width: Int
            let lowerBound: UInt32
            switch byte {
            case 0x00...0x7F: i += 1; continue
            case 0xC2...0xDF: width = 2; lowerBound = 0x80
            case 0xE0...0xEF: width = 3; lowerBound = 0x800
            case 0xF0...0xF4: width = 4; lowerBound = 0x10000
            default: return i          // continuation byte or C0/C1/F5+ as a lead
            }
            guard i + width <= count else { return i }

            var scalar = UInt32(byte & (0xFF >> UInt8(width + 1)))
            for k in 1..<width {
                let continuation = bytes[i + k]
                guard continuation & 0xC0 == 0x80 else { return i }
                scalar = (scalar << 6) | UInt32(continuation & 0x3F)
            }
            // Reject overlong encodings and surrogates, both of which decode to
            // plausible-looking scalars but are illegal in UTF-8.
            guard scalar >= lowerBound, scalar <= 0x10FFFF,
                  !(0xD800...0xDFFF).contains(scalar) else { return i }
            i += width
        }
        return nil
    }
}
