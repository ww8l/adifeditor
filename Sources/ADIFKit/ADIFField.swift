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

    /// LENGTH exactly as the file spelled it — `5`, but also `005` and `+5`, which are
    /// the same number and not the same bytes. `nil` for a field this app created, which
    /// has no spelling to preserve.
    ///
    /// Honoured by the writer only while it still describes the value. Edit the cell and
    /// a fresh count is computed: re-emitting a length known to be wrong is the one thing
    /// §6.2a's exception exists to forbid.
    public var lengthSpelling: String?

    /// Everything after the second colon, exactly as the file wrote it: the `D` in
    /// `<QSO_DATE:8:D>`, but also the `DATE` in `<QSO_DATE:8:DATE>` and the `S:X` in
    /// `<CALL:5:S:X>`.
    ///
    /// Held as text rather than a single `Character` for the same reason `spelling` is
    /// held rather than a normalized name (decision 3) — re-rendering from a `Character`
    /// dropped the rest and rewrote a file nobody had edited. `nil` means there was no
    /// second colon at all; `""` means there was one with nothing after it, and those
    /// are different bytes.
    public var typeSpelling: String?

    /// The first character of the type indicator, which is what the ADIF spec's own
    /// one-letter codes amount to. Read-only: `typeSpelling` is what gets written.
    public var typeIndicator: Character? { typeSpelling?.first }

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
        lengthSpelling: String? = nil,
        typeSpelling: String? = nil,
        trailingText: String = ""
    ) {
        self.spelling = spelling
        self.value = value
        self.lengthSpelling = lengthSpelling
        self.typeSpelling = typeSpelling
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
