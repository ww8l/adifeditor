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

    /// Index of the next `<` or `>` at or after `from`, or `nil` when neither remains.
    ///
    /// Exists so the recovery path can ask "did the file end inside this tag?" without
    /// materializing the rest of the file as a `String` to search it. Doing that made
    /// the scan quadratic: 80 KB of a downloaded HTML error page took 21 seconds.
    private func indexOfNextBracket(from: Int) -> Int? {
        var i = from
        while i < scalars.count {
            if scalars[i] == "<" || scalars[i] == ">" { return i }
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

        /// The LENGTH as a usable number. `nil` for a terminator, which carries no
        /// LENGTH at all, and also for a field whose LENGTH is present but not a
        /// non-negative integer — the two are told apart by `hasLength`.
        var declaredLength: Int?

        /// True when the tag carried a `:`, which is what makes it a field rather than
        /// a terminator. A broken LENGTH does not stop a field being a field.
        var hasLength: Bool

        /// The LENGTH exactly as the file spelled it, for the diagnostic. "" when the
        /// tag carried none.
        var lengthSpelling: String

        /// Everything after the second colon, verbatim. `nil` when there was none.
        var typeSpelling: String?

        /// Index just past the closing `>`.
        var end: Int

        /// A tag with no LENGTH at all is a terminator: `<EOR>`, `<EOH>`.
        var isTerminator: Bool { !hasLength }
    }

    /// True when `spelling` could be an ADIF field name. ADIF restricts them to ASCII
    /// letters, digits and underscore (§8).
    ///
    /// This gates only the broken-LENGTH recovery below, never a well-formed tag: a
    /// logger emitting `<MY-FIELD:3>abc` still gets its field. What it rules out is
    /// treating `<a href="http://example.com/x">` — the shape a failed log download
    /// arrives in — as a field named `a href="http`, which would put a column of HTML
    /// in the grid.
    private static func isPlausibleFieldName(_ spelling: String) -> Bool {
        guard !spelling.isEmpty else { return false }
        for scalar in spelling.unicodeScalars {
            switch scalar.value {
            case 0x41...0x5A, 0x61...0x7A, 0x30...0x39, 0x5F: continue
            default: return false
            }
        }
        return true
    }

    /// Parses the tag starting at `start` (which must be a `<`).
    ///
    /// Returns `nil` when what sits there cannot be a tag at all — unterminated, empty,
    /// or with a second `<` inside it before any `>`. That last case is not pedantry:
    /// scanning past an embedded `<` to a later `>` turns `<<MODE:3>FT8` into a field
    /// genuinely named `<MODE`, and because the result looks well-formed no diagnostic
    /// ever fires. The bogus column reaches the grid in silence.
    ///
    /// A tag whose LENGTH is not a number is *not* `nil`. It is a field with a broken
    /// length, and rung 4 of decision 5's ladder recovers its value — dropping it would
    /// lose a field the file plainly contains, which §11 forbids.
    private func parseTag(at start: Int) -> Tag? {
        guard start < scalars.count, scalars[start] == "<" else { return nil }
        var close = start + 1
        while close < scalars.count, scalars[close] != ">" {
            if scalars[close] == "<" { return nil }       // a new tag opens; this never closed
            close += 1
        }
        guard close < scalars.count else { return nil }   // unterminated

        let body = text((start + 1)..<close)
        guard !body.isEmpty else { return nil }
        let parts = body.split(separator: ":", omittingEmptySubsequences: false)
        let spelling = String(parts[0])
        guard !spelling.isEmpty else { return nil }

        if parts.count == 1 {
            return Tag(spelling: spelling, declaredLength: nil, hasLength: false,
                       lengthSpelling: "", typeSpelling: nil, end: close + 1)
        }

        let lengthSpelling = String(parts[1])
        // Everything past the second colon, rejoined. `<CALL:5:S:X>` keeps its `S:X`
        // and `<CALL:5:>` keeps an empty-but-present indicator; taking only the first
        // character of `parts[2]` discarded both and rewrote the file (§6.2a).
        let type = parts.count > 2
            ? parts[2...].map(String.init).joined(separator: ":")
            : nil
        if let length = Int(lengthSpelling), length >= 0 {
            return Tag(spelling: spelling, declaredLength: length, hasLength: true,
                       lengthSpelling: lengthSpelling, typeSpelling: type,
                       end: close + 1)
        }
        // The LENGTH is unusable. Keep the field only if its name is one, so that
        // recovery cannot manufacture columns out of markup.
        guard ADIFScanner.isPlausibleFieldName(spelling) else { return nil }
        return Tag(spelling: spelling, declaredLength: nil, hasLength: true,
                   lengthSpelling: lengthSpelling, typeSpelling: type, end: close + 1)
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
        let valueStart = tag.end

        guard let declared = tag.declaredLength else {
            // 0 — The LENGTH is not a number, so there is nothing to try the ladder on.
            //     Recover the value the way rung 4 does and keep the field.
            return recoverValue(from: valueStart) { recovered in
                .unparseableLength(field: tag.spelling,
                                   declared: tag.lengthSpelling,
                                   recovered: recovered)
            }
        }

        // 1 — LENGTH as scalars, the common case. Accepted when only whitespace stands
        //     between the value and the next tag.
        //
        //     Written as a comparison against what remains rather than as
        //     `min(valueStart + declared, scalars.count)`, because that addition traps
        //     on overflow for a length near `Int.max` and killed the process outright —
        //     from a header field, before a window ever appeared (§6.4).
        let endAsScalars = declared > scalars.count - valueStart
            ? scalars.count
            : valueStart + declared
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
        return recoverValue(from: valueStart) { recovered in
            .lengthMismatch(field: tag.spelling,
                            declared: declared,
                            recovered: recovered)
        }
    }

    /// Rung 4's recovery, shared with the unusable-LENGTH case: the value runs from
    /// `valueStart` to the next `<`, less any trailing whitespace. `warning` is handed
    /// the recovered length so each caller can name its own fault.
    private mutating func recoverValue(
        from valueStart: Int,
        warning: (Int) -> ADIFWarning.Kind
    ) -> (value: String, trailing: String) {
        let next = indexOfNextTagStart(from: valueStart) ?? scalars.count
        var valueEnd = next
        while valueEnd > valueStart,
              CharacterSet.whitespacesAndNewlines.contains(scalars[valueEnd - 1]) {
            valueEnd -= 1
        }
        warn(warning(valueEnd - valueStart))
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
                // Not a tag. If no bracket of any kind follows, the file ended mid-tag;
                // otherwise this `<` is stray, so skip it and resume at the next one.
                //
                // An index scan, not a substring: materializing the rest of the file to
                // ask whether it holds a `>` is what made this loop quadratic.
                if indexOfNextBracket(from: tagStart + 1) == nil {
                    let rest = text(tagStart..<scalars.count)
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
                          lengthSpelling: tag.lengthSpelling,
                          typeSpelling: tag.typeSpelling,
                          trailingText: trailing)
            )
        }

        return result
    }
}
