import Foundation

/// A POTA park reference, such as `US-1234`.
///
/// Validation is deliberately lenient (§10.2). The format is a short alphanumeric prefix,
/// a hyphen, and four or five digits — but POTA's scheme has changed before and will
/// change again, and a validator that refuses a reference that turns out to be real is
/// worse than one that lets a typo through to a grid the operator is looking at anyway.
/// So `isWellFormed` is advice for the interface to show, never grounds for refusal.
public struct ParkReference: Equatable, Hashable, Sendable {

    /// Exactly what the operator typed, minus surrounding whitespace. This is what gets
    /// written into `MY_SIG_INFO` and into filenames — never a "corrected" version.
    public let text: String

    public init(_ text: String) {
        self.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether the reference matches POTA's current shape. Advisory only.
    public var isWellFormed: Bool {
        guard let hyphen = text.firstIndex(of: "-") else { return false }

        let prefix = text[text.startIndex..<hyphen]
        let digits = text[text.index(after: hyphen)...]

        guard (1...4).contains(prefix.count),
              prefix.allSatisfy({ $0.isLetter || $0.isNumber }),
              (4...5).contains(digits.count),
              digits.allSatisfy(\.isNumber)
        else { return false }

        return true
    }

    public var isEmpty: Bool { text.isEmpty }

    /// Splits what the operator typed into references.
    ///
    /// Accepts commas, spaces and newlines as separators, because an operator copying
    /// references out of the POTA site or their own notes will produce any of them, and
    /// guessing wrong means silently stamping one park with a value like `US-1234,
    /// US-5678`. Duplicates are dropped, keeping first appearance: stamping the same park
    /// twice would write the same file twice.
    public static func list(from input: String) -> [ParkReference] {
        let separators = CharacterSet(charactersIn: ", \t\n\r;")
        var seen = Set<String>()

        return input
            .components(separatedBy: separators)
            .map(ParkReference.init)
            .filter { !$0.isEmpty }
            .filter { seen.insert($0.text.uppercased()).inserted }
    }
}
