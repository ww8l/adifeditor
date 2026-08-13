import Foundation

/// Low-level tag scanner over ADI text.
///
/// Works in Unicode scalars rather than `Character`s. ADIF's LENGTH counts code points,
/// and Swift's `Character` is a grapheme cluster — it would fuse `e` + combining acute
/// into one unit where every ADI writer in existence counts two, turning well-formed
/// files into apparent length errors.
struct ADIFScanner {
    let scalars: [Unicode.Scalar]

    /// Current position. Moves forward only.
    var index: Int = 0

    /// Byte offset of `index` into the original text, maintained incrementally so
    /// warnings can name a position (§6.4) without rescanning the file each time.
    var byteOffset: Int = 0

    var warnings: [ADIFWarning] = []

    init(text: String) {
        self.scalars = Array(text.unicodeScalars)
    }

    var isAtEnd: Bool { index >= scalars.count }

    /// Result of scanning up to a terminator tag such as `<EOR>` or `<EOH>`.
    struct ScanResult {
        var fields: [ADIFField] = []
        /// Text found before the first field. Only non-empty in malformed input, where
        /// it still has to be carried so the bytes survive.
        var leadingText: String = ""
        /// The terminator's spelling without brackets — `EOR`, `eor`, `EOH`.
        /// `nil` when the input ended before any terminator was found.
        var terminatorSpelling: String?
        /// Text after the terminator, up to the next `<` or end of input.
        var trailingText: String = ""
        /// True when input ended before a terminator.
        var isTruncated: Bool = false
        /// True when nothing at all was found — no fields, no terminator.
        var isEmpty: Bool { fields.isEmpty && terminatorSpelling == nil }
    }

    // MARK: - Cursor

    /// Advances to `newIndex`, keeping `byteOffset` in step.
    private mutating func advance(to newIndex: Int) {
        precondition(newIndex >= index, "the scanner cursor only moves forward")
        for i in index..<min(newIndex, scalars.count) {
            byteOffset += UTF8.width(scalars[i])
        }
        index = min(newIndex, scalars.count)
    }

    /// Index of the next `<` at or after `from`, or `nil`.
    private func indexOfNextTagStart(from: Int) -> Int? {
        var i = from
        while i < scalars.count {
            if scalars[i] == "<" { return i }
            i += 1
        }
        return nil
    }

    private func text(_ range: Range<Int>) -> String {
        var view = String.UnicodeScalarView()
        for i in range.clamped(to: 0..<scalars.count) { view.append(scalars[i]) }
        return String(view)
    }

    private func isAllWhitespace(_ range: Range<Int>) -> Bool {
        for i in range.clamped(to: 0..<scalars.count) {
            if !CharacterSet.whitespacesAndNewlines.contains(scalars[i]) { return false }
        }
        return true
    }

    // MARK: - Tags

    /// A parsed `<...>` tag header, before its value is read.
    private struct Tag {
        var spelling: String
        var declaredLength: Int?
        var typeIndicator: Character?
        /// Index just past the closing `>`.
        var end: Int
        /// A tag with no length is a terminator: `<EOR>`, `<EOH>`.
        var isTerminator: Bool { declaredLength == nil }
    }

    /// Parses the tag starting at `start` (which must be a `<`). Returns `nil` if the
    /// tag is unterminated or its length field is not a number.
    private func parseTag(at start: Int) -> Tag? {
        guard start < scalars.count, scalars[start] == "<" else { return nil }
        var close = start + 1
        while close < scalars.count, scalars[close] != ">" { close += 1 }
        guard close < scalars.count else { return nil }   // unterminated

        let body = text((start + 1)..<close)
        guard !body.isEmpty else { return nil }
        let parts = body.split(separator: ":", omittingEmptySubsequences: false)
        let spelling = String(parts[0])
        guard !spelling.isEmpty else { return nil }

        if parts.count == 1 {
            return Tag(spelling: spelling, declaredLength: nil,
                       typeIndicator: nil, end: close + 1)
        }
        guard let length = Int(parts[1]), length >= 0 else { return nil }
        let type = parts.count > 2 ? parts[2].first : nil
        return Tag(spelling: spelling, declaredLength: length,
                   typeIndicator: type, end: close + 1)
    }

    /// True when a well-formed tag begins at `start`. Used to decide whether a run of
    /// unexpected text is followed by something worth resuming at.
    private func opensWellFormedTag(at start: Int) -> Bool {
        parseTag(at: start) != nil
    }

    // MARK: - Values

    /// Reads a field's value, applying the recovery ladder from CLAUDE.md decision 5.
    ///
    /// Returns the value and the literal text separating it from the next `<`.
    private mutating func readValue(tag: Tag) -> (value: String, trailing: String) {
        let declared = tag.declaredLength ?? 0
        let valueStart = tag.end

        // 1 — LENGTH as scalars, the common case. Accepted when only whitespace stands
        //     between the value and the next tag.
        let endAsScalars = min(valueStart + declared, scalars.count)
        if endAsScalars - valueStart == declared {
            let next = indexOfNextTagStart(from: endAsScalars) ?? scalars.count
            if isAllWhitespace(endAsScalars..<next) {
                return accept(valueStart..<endAsScalars, upTo: next)
            }
        }

        // 2 — LENGTH as UTF-8 bytes. Some writers emit a byte count for non-ASCII data;
        //     §8 calls this out as the format's sharpest edge.
        if let endAsBytes = indexConsumingUTF8Bytes(declared, from: valueStart),
           endAsBytes != endAsScalars {
            let next = indexOfNextTagStart(from: endAsBytes) ?? scalars.count
            if isAllWhitespace(endAsBytes..<next) {
                warn(.lengthInterpretedAsBytes(field: tag.spelling,
                                               declared: declared,
                                               actual: endAsBytes - valueStart))
                return accept(valueStart..<endAsBytes, upTo: next)
            }
        }

        // 3 — Neither reading lands on whitespace. Two different faults look identical
        //     here, and the scalar immediately after the declared length tells them
        //     apart: whitespace means the length was honest and stray text follows;
        //     anything else means the length itself was wrong.
        if endAsScalars - valueStart == declared,
           endAsScalars < scalars.count,
           CharacterSet.whitespacesAndNewlines.contains(scalars[endAsScalars]) {
            let next = indexOfNextTagStart(from: endAsScalars) ?? scalars.count
            warn(.unexpectedTextBetweenFields(text: text(endAsScalars..<next)))
            return accept(valueStart..<endAsScalars, upTo: next)
        }

        // 4 — The length was wrong. Resynchronize from the *start of the value* to the
        //     next `<` (§8). Scanning from the end of the declared length instead would
        //     swallow the following field whenever the length overran.
        let next = indexOfNextTagStart(from: valueStart) ?? scalars.count
        var valueEnd = next
        while valueEnd > valueStart,
              CharacterSet.whitespacesAndNewlines.contains(scalars[valueEnd - 1]) {
            valueEnd -= 1
        }
        warn(.lengthMismatch(field: tag.spelling,
                             declared: declared,
                             recovered: valueEnd - valueStart))
        return accept(valueStart..<valueEnd, upTo: next)
    }

    /// Materializes a value and its trailing separator, moving the cursor past both.
    private mutating func accept(
        _ valueRange: Range<Int>, upTo next: Int
    ) -> (value: String, trailing: String) {
        let value = text(valueRange)
        let trailing = text(valueRange.upperBound..<next)
        advance(to: next)
        return (value, trailing)
    }

    /// The index at which exactly `byteCount` UTF-8 bytes have been consumed from
    /// `start`, or `nil` if no scalar boundary lands there.
    private func indexConsumingUTF8Bytes(_ byteCount: Int, from start: Int) -> Int? {
        var bytes = 0
        var i = start
        while i < scalars.count, bytes < byteCount {
            bytes += UTF8.width(scalars[i])
            i += 1
        }
        return bytes == byteCount ? i : nil
    }

    private mutating func warn(_ kind: ADIFWarning.Kind) {
        warnings.append(ADIFWarning(kind: kind, byteOffset: byteOffset))
    }

    // MARK: - Records

    /// Scans fields until a terminator tag (`<EOR>`, `<EOH>`) or the end of input.
    mutating func scanFieldsToTerminator() -> ScanResult {
        var result = ScanResult()

        while true {
            guard let tagStart = indexOfNextTagStart(from: index) else {
                // No further tags. Leftover text goes after the terminator the writer
                // will synthesize, never before it: text placed before a synthesized
                // `<EOR>` can fuse with it into a tag that never existed.
                if index < scalars.count {
                    result.trailingText += text(index..<scalars.count)
                    advance(to: scalars.count)
                }
                if !result.fields.isEmpty {
                    result.isTruncated = true
                    warn(.truncatedFinalRecord(fieldCount: result.fields.count))
                }
                result.terminatorSpelling = nil
                break
            }

            // Text between the previous field and this tag belongs to the previous
            // field's separator; the loop below only reaches here when a value read
            // stopped short, so preserve whatever sits in the gap.
            if tagStart > index {
                let gap = text(index..<tagStart)
                if !result.fields.isEmpty {
                    result.fields[result.fields.count - 1].trailingText += gap
                } else if !gap.isEmpty {
                    result.leadingText += gap
                }
                advance(to: tagStart)
            }

            guard let tag = parseTag(at: tagStart) else {
                // Unterminated or unparseable tag. If there is no `>` at all the file
                // ended mid-tag; otherwise skip this `<` and resynchronize.
                let rest = text(tagStart..<scalars.count)
                if !rest.contains(">") {
                    warn(.truncatedTag(partial: String(rest.prefix(40))))
                    if result.fields.isEmpty {
                        result.leadingText += rest
                    } else {
                        // After the synthesized terminator, for the reason above.
                        result.trailingText += rest
                    }
                    advance(to: scalars.count)
                    result.isTruncated = !result.fields.isEmpty
                    break
                }
                warn(.resynchronized(skipped: 1))
                if !result.fields.isEmpty {
                    result.fields[result.fields.count - 1].trailingText += "<"
                } else {
                    result.leadingText += "<"
                }
                advance(to: tagStart + 1)
                continue
            }

            if tag.isTerminator {
                advance(to: tag.end)
                let next = indexOfNextTagStart(from: index) ?? scalars.count
                result.terminatorSpelling = tag.spelling
                result.trailingText = text(index..<next)
                advance(to: next)
                break
            }

            advance(to: tag.end)
            let (value, trailing) = readValue(tag: tag)
            result.fields.append(
                ADIFField(spelling: tag.spelling,
                          value: value,
                          typeIndicator: tag.typeIndicator,
                          trailingText: trailing)
            )
        }

        return result
    }
}
