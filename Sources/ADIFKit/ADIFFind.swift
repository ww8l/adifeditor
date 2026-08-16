import Foundation

/// Which QSOs contain a piece of text, and how to step through them.
///
/// Find moves the selection; it never hides a row and never changes the log. That is the
/// whole of it — narrowing the grid to a subset was considered and dropped as more
/// machinery than the job needs.
///
/// The stepping lives here rather than in the grid because wrapping is where this kind of
/// code goes wrong: off the end, off the front, one match, no matches, and a starting row
/// that is itself a match. Those are cheap to test and awkward to notice by hand.
public struct FindMatches: Equatable, Sendable {

    /// Record indices that matched, ascending.
    public let rows: [Int]

    public init(rows: [Int] = []) {
        self.rows = rows
    }

    public var count: Int { rows.count }
    public var isEmpty: Bool { rows.isEmpty }

    /// The first match after `row`, wrapping to the beginning. Passing `nil` — nothing
    /// selected — starts at the top.
    ///
    /// Strictly after, so pressing Find Next on a row that already matches advances
    /// instead of sitting still.
    public func next(after row: Int?) -> Int? {
        guard !rows.isEmpty else { return nil }
        guard let row else { return rows.first }
        return rows.first { $0 > row } ?? rows.first
    }

    /// The last match before `row`, wrapping to the end.
    public func previous(before row: Int?) -> Int? {
        guard !rows.isEmpty else { return nil }
        guard let row else { return rows.last }
        return rows.last { $0 < row } ?? rows.last
    }

    /// Where a record sits in the match list, counting from one, for "3 of 7".
    /// `nil` when that record is not a match.
    public func ordinal(of row: Int) -> Int? {
        rows.firstIndex(of: row).map { $0 + 1 }
    }
}

extension ADIFDocument {

    /// Records holding `text` in any field, case-insensitively.
    ///
    /// Every column is searched rather than one chosen in advance: a callsign, a park
    /// reference and a grid square are all just text you half-remember, and making the
    /// operator say which column it lives in first is a question they should not have to
    /// answer to find something.
    ///
    /// Field *names* are not searched. Typing `CALL` should find the QSO whose comment
    /// mentions a call, not every record in the log.
    public func find(_ text: String) -> FindMatches {
        guard !text.isEmpty else { return FindMatches() }

        return FindMatches(rows: records.indices.filter { index in
            records[index].fields.contains { field in
                field.value.range(of: text,
                                  options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
        })
    }
}
