import Foundation

/// What an edit *means* to the data, kept here rather than in the app layer.
///
/// Deciding that clearing a cell removes a field is a round-trip question, not a user
/// interface question — get it wrong and a saved file quietly differs from the one that
/// was opened. Living in ADIFKit, these rules are covered by the same suite that guards
/// §11, and the document layer above is left with only undo, dirty state and redisplay.
extension ADIFDocument {

    /// The record that results from setting one cell, or `nil` when the edit changes
    /// nothing and should not be recorded.
    ///
    /// Pure: it computes a new record and does not touch the document. The caller
    /// applies it, which is what lets the app register undo around the assignment.
    ///
    /// Three cases, and the difference between the first two is decision 2:
    ///
    ///   - clearing a cell that held a value **removes the field**, because that is an
    ///     edit the user made;
    ///   - clearing a cell that was already empty changes nothing, so a `<COMMENT:0>`
    ///     that arrived in the file survives untouched;
    ///   - typing into a cell whose field is absent **adds the field**, spelled the way
    ///     the rest of the file spells it (decision 3).
    ///
    /// `columnOrder` says where a re-added field belongs. Left out, the order is merged
    /// from the records themselves, which has no answer for a field that exactly one
    /// record carried: clearing that cell takes the column out of the file entirely, so
    /// retyping the same value appends the field to the end of the record and the file
    /// no longer matches the one that was opened — decision 14's own symptom, one step
    /// removed. The grid keeps its columns for the life of the window and can say where
    /// the column was, so the app passes that in.
    public func recordBySettingValue(
        _ newValue: String,
        forColumn column: String,
        inRecordAt index: Int,
        columnOrder: [String]? = nil
    ) -> ADIFRecord? {
        guard records.indices.contains(index) else { return nil }

        var record = records[index]

        // Treating an absent field as empty is what makes "clear an empty cell" and
        // "clear an absent cell" both compare equal and register nothing.
        guard (record[column] ?? "") != newValue else { return nil }

        if newValue.isEmpty {
            record[column] = nil
        } else if record.hasField(column) {
            // Assigns through the existing field, so its position in the record, its
            // spelling and its type indicator all survive the edit.
            record[column] = newValue
        } else {
            record.insertField(named: spelling(forColumn: column),
                               value: newValue,
                               at: position(forColumn: column,
                                            in: record,
                                            using: columnOrder ?? columnNames))
        }

        return record
    }

    /// The records reordered by one column.
    ///
    /// Compared as text, always. ADIF values are strings and this app does not coerce
    /// types (§9) — sorting `RST_SENT` numerically would mean deciding that `-12` is a
    /// number rather than the text the logger wrote, which is exactly the inference
    /// decision 12 rules out. Dates and times sort correctly as text anyway, being
    /// fixed-width `YYYYMMDD` and `HHMMSS`.
    ///
    /// Stable: records that tie keep the order they were already in. That is what makes
    /// sorting by date and then by time do the useful thing rather than shuffling the
    /// first sort away.
    public func recordsSorted(byColumn column: String, ascending: Bool) -> [ADIFRecord] {
        records.enumerated().sorted { left, right in
            // An absent field and an empty one compare the same, so a column only some
            // QSOs carry gathers its blanks at one end instead of scattering them.
            let a = left.element[column] ?? ""
            let b = right.element[column] ?? ""

            switch a.caseInsensitiveCompare(b) {
            case .orderedAscending: return ascending
            case .orderedDescending: return !ascending
            case .orderedSame: return left.offset < right.offset
            }
        }.map(\.element)
    }

    /// The records with the given rows removed.
    ///
    /// Removes from the highest index down so that each removal cannot shift the ones
    /// still to come — the classic way to delete the wrong QSO.
    public func recordsByDeleting(at indexes: IndexSet) -> [ADIFRecord] {
        var remaining = records
        for index in indexes.sorted(by: >) where remaining.indices.contains(index) {
            remaining.remove(at: index)
        }
        return remaining
    }

    /// Where a field being added back to a record belongs among its existing fields.
    ///
    /// Taken from the column order, which is itself merged from every record (see
    /// `columnNames`): the field goes before the first field of this record that sits
    /// after it in that order. So a `gridsquare` retyped into a cleared cell lands back
    /// between `QSL_MANUAL` and `mode`, where the file's other records keep it, rather
    /// than at the end of the record.
    ///
    /// Falls back to the end of the record when `order` does not mention the field at
    /// all, which is the genuinely new column case — there is nothing to take a position
    /// from.
    private func position(forColumn column: String,
                          in record: ADIFRecord,
                          using order: [String]) -> Int {
        var rank: [String: Int] = [:]
        for (index, name) in order.enumerated() { rank[name] = index }

        guard let target = rank[ADIFField.normalize(column)] else { return record.fields.count }

        for (index, field) in record.fields.enumerated() {
            if let position = rank[field.name], position > target { return index }
        }
        return record.fields.count
    }

    /// How this file spells a field name, taken from the first record that carries it.
    ///
    /// A file whose fields are lower case should not acquire a shouting `MY_SIG_INFO`
    /// among them just because the grid's column headers are normalized. Falls back to
    /// the normalized name when no record has the field — which is the case where every
    /// record's copy of it has been cleared.
    public func spelling(forColumn column: String) -> String {
        let key = ADIFField.normalize(column)
        for record in records {
            if let field = record.fields.first(where: { $0.name == key }) {
                return field.spelling
            }
        }
        return key
    }
}
