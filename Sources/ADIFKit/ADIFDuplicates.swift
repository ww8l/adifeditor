import Foundation

/// A set of records that agree on the fields being compared.
///
/// `original` is the one to keep and `duplicates` are the ones after it. Which is which
/// is decided by position alone — the earliest occurrence stays — because any cleverer
/// rule would mean judging which of two identical-looking QSOs is the better record, and
/// nothing in the data says that.
public struct DuplicateGroup: Equatable, Sendable {
    public let original: Int
    public let duplicates: [Int]

    public init(original: Int, duplicates: [Int]) {
        self.original = original
        self.duplicates = duplicates
    }
}

extension ADIFDocument {

    /// Groups of records that match on every one of `fields`.
    ///
    /// Values compare as text and case-insensitively, so `w1abc` and `W1ABC` are the same
    /// station. An absent field and an empty one compare equal, which means two QSOs that
    /// both lack `BAND` match on `BAND` — the honest reading, since the log does not
    /// distinguish "no band recorded" from "no band recorded".
    ///
    /// An empty field list matches everything and would report the entire log as
    /// duplicates of its first record, so it returns nothing instead. The interface
    /// disables the button too, but the guarantee belongs here where it is testable.
    ///
    /// Records are visited in order, so `original` is always the earliest of its group
    /// and the reported duplicates are always later in the file.
    public func duplicateGroups(matching fields: [String]) -> [DuplicateGroup] {
        guard !fields.isEmpty else { return [] }

        let keys = fields.map { ADIFField.normalize($0) }

        // Keyed on the array of values rather than a joined string: any separator could
        // appear inside a COMMENT or NOTES value, and two different records would then
        // collide into one key.
        var firstSeenAt: [[String]: Int] = [:]
        var duplicatesOf: [Int: [Int]] = [:]
        var order: [Int] = []

        for (index, record) in records.enumerated() {
            let key = keys.map { (record[$0] ?? "").uppercased() }

            if let original = firstSeenAt[key] {
                if duplicatesOf[original] == nil { order.append(original) }
                duplicatesOf[original, default: []].append(index)
            } else {
                firstSeenAt[key] = index
            }
        }

        return order.map { DuplicateGroup(original: $0, duplicates: duplicatesOf[$0] ?? []) }
    }

    /// Every row that `duplicateGroups(matching:)` would remove, flattened.
    public func duplicateRows(matching fields: [String]) -> IndexSet {
        var rows = IndexSet()
        for group in duplicateGroups(matching: fields) {
            for duplicate in group.duplicates { rows.insert(duplicate) }
        }
        return rows
    }
}
