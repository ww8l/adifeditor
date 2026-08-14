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
    public func recordBySettingValue(
        _ newValue: String,
        forColumn column: String,
        inRecordAt index: Int
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
            record.appendField(named: spelling(forColumn: column), value: newValue)
        }

        return record
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
