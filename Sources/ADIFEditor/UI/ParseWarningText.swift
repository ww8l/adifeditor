import Foundation
import ADIFKit

/// Turns parser warnings into the plain-language diagnostic §6.4 asks for.
///
/// Lives in the UI layer, not ADIFKit, so the parser stays free of presentation
/// concerns and of anything that would need localizing.
enum ParseWarningText {

    /// One line summarizing a file's warnings, for the banner under the title bar.
    static func summary(_ warnings: [ADIFWarning]) -> String {
        guard let first = warnings.first else { return "" }
        guard warnings.count > 1 else { return describe(first) }
        let others = warnings.count - 1
        let plural = others == 1 ? "problem" : "problems"
        return "\(describe(first)) (and \(others) other \(plural))"
    }

    static func describe(_ warning: ADIFWarning) -> String {
        "\(sentence(for: warning.kind)) At byte \(warning.byteOffset)."
    }

    private static func sentence(for kind: ADIFWarning.Kind) -> String {
        switch kind {
        case .lengthInterpretedAsBytes(let field, let declared, let actual):
            return "\(field) declared a length of \(declared), which matched only when "
                 + "read as bytes rather than characters (\(actual) characters). The "
                 + "value was read correctly and will be written with a corrected length."

        case .lengthMismatch(let field, let declared, let recovered):
            return "\(field) declared a length of \(declared) but held \(recovered) "
                 + "characters. The value was recovered by reading to the next field."

        case .unexpectedTextBetweenFields(let text):
            return "Unexpected text between fields: \(quoted(text)). It belongs to no "
                 + "field and has been left where it was."

        case .resynchronized(let skipped):
            return "\(skipped) characters could not be read as ADIF and were skipped."

        case .truncatedFinalRecord(let fieldCount):
            let plural = fieldCount == 1 ? "field" : "fields"
            return "The file ends before the last QSO's <EOR>. Its \(fieldCount) "
                 + "\(plural) were kept."

        case .truncatedTag(let partial):
            return "The file ends inside the tag \(quoted(partial))."
        }
    }

    /// Truncates before quoting: stray text can be arbitrarily long, and a banner is not
    /// the place to discover that.
    private static func quoted(_ text: String, limit: Int = 40) -> String {
        let cleaned = text
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
        guard cleaned.count > limit else { return "\"\(cleaned)\"" }
        return "\"\(cleaned.prefix(limit))…\""
    }
}
