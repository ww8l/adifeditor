import Foundation

/// A single `<NAME:LENGTH>value` or `<NAME:LENGTH:TYPE>value` field.
///
/// The stored properties exist to satisfy byte-identity (CLAUDE.md §6.2a). A field is
/// not merely a name and a value: it remembers how the file spelled its name, whether
/// it carried a type indicator, and what text separated it from whatever came next.
/// Drop any of those and an unedited file no longer round-trips.
public struct ADIFField: Equatable, Sendable {
    /// The field name exactly as the file spelled it — `call`, `CALL`, or `Call`.
    public var spelling: String

    /// The value. Never `nil`; a `<COMMENT:0>` field has an empty value and is still
    /// a field that was present in the input (decision 2).
    public var value: String

    /// The optional data-type indicator: the `D` in `<QSO_DATE:8:D>`.
    public var typeIndicator: Character?

    /// Literal text between this field's value and the next `<`. Usually "" or " ".
    ///
    /// §8 says text between fields "is not part of any field and is ignored" — ignored
    /// for *interpretation*, but it is still bytes in the user's file, so it is carried
    /// here and written back verbatim. The FT8CN fixture puts a space after all 1056 of
    /// its fields; discarding those would change every line of the file.
    public var trailingText: String

    public init(
        spelling: String,
        value: String,
        typeIndicator: Character? = nil,
        trailingText: String = ""
    ) {
        self.spelling = spelling
        self.value = value
        self.typeIndicator = typeIndicator
        self.trailingText = trailingText
    }

    /// The uppercased name, which is what all lookups and comparisons key on.
    ///
    /// ADIF field names are case-insensitive (§8), so `call` and `CALL` are the same
    /// field — but only for lookup. `spelling` is what gets written.
    public var name: String {
        ADIFField.normalize(spelling)
    }

    /// Normalizes a field name for lookup: uppercase, using the ASCII-only fast path.
    ///
    /// Deliberately not locale-aware. Turkish locale lowercases `I` to a dotless `ı`,
    /// which would make `TIME_ON` fail to match itself on a Turkish system.
    public static func normalize(_ rawName: String) -> String {
        rawName.uppercased()
    }
}
