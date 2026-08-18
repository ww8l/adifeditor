import Foundation

/// Serializes an `ADIFDocument` back to ADI bytes.
///
/// The contract is byte-identity (CLAUDE.md §6.2a): for a well-formed file that has not
/// been edited, `write(parse(data)) == data`. That is only achievable because the model
/// carries the file's own spellings and separators rather than a normalized view of
/// them, so the writer's job is mostly to put back what the parser found.
///
/// Deliberately absent: any concept of an output "style", any normalization of field
/// name case, any reordering, any header synthesis for files that came in without one.
public enum ADIFWriter {

    public static func write(_ document: ADIFDocument) -> Data {
        var out = ""
        if document.byteOrderMark { out.unicodeScalars.append("\u{FEFF}") }
        if let header = document.header { out += header }

        for record in document.records {
            for field in record.fields {
                out += render(field)
                out += field.trailingText
            }
            // A record truncated on input still needs a terminator on output; that is
            // the file being repaired at the exact site of its defect, which is the one
            // permitted departure from byte-identity.
            out += "<\(record.terminatorSpelling)>"
            out += record.trailingText
        }

        return Data(out.utf8)
    }

    /// Renders one field as `<NAME:LENGTH>value` or `<NAME:LENGTH:TYPE>value`.
    ///
    /// LENGTH is a count of Unicode scalars, which is what a conforming writer emits
    /// and what every well-formed fixture uses. A file that arrived with byte counts
    /// therefore goes out with scalar counts — a change, but confined to the defect the
    /// parser already warned about, and the alternative is re-emitting a length we know
    /// to be wrong.
    ///
    /// Everything else about the tag comes back as the file wrote it. `005` and `+5` are
    /// both the number 5 and neither is the bytes `5`; normalizing them changed unedited
    /// files with no warning, which §6.2a forbids twice over — once for the change, once
    /// for the silence.
    static func render(_ field: ADIFField) -> String {
        let count = field.value.unicodeScalars.count

        // The file's own spelling, but only while it still describes the value. An
        // edited cell gets a freshly counted length, spelled plainly.
        let length = field.lengthSpelling.flatMap { Int($0) == count ? $0 : nil }
            ?? String(count)

        if let type = field.typeSpelling {
            return "<\(field.spelling):\(length):\(type)>\(field.value)"
        }
        return "<\(field.spelling):\(length)>\(field.value)"
    }
}
