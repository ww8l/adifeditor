import Foundation
import ADIFKit

/// One cell the lookup would fill: a row, a field, and the value QRZ supplied.
///
/// Every one of these is shown to the operator, individually untickable, before any of
/// them is written (§10.4).
public struct ProposedFill: Equatable, Sendable {
    public let row: Int
    public let field: String
    public let value: String

    public init(row: Int, field: String, value: String) {
        self.row = row
        self.field = field
        self.value = value
    }
}

/// Turning QRZ records into proposed edits.
///
/// Deliberately free of networking: everything here is a pure function of a document and
/// a bag of already-fetched records. `QRZBatch` does the fetching. Splitting it this way
/// is what lets §6.3 — fill empty cells, never overwrite — be tested exhaustively without
/// a socket, which matters more than usual now that the OS no longer enforces §6.5.
public enum QRZLookup {

    /// The distinct callsigns worth looking up across `rows`.
    ///
    /// Uppercased and de-duplicated, so a log with eight QSOs against the same park
    /// activator costs one request rather than eight. Order follows the rows, so the
    /// operator sees progress in the order they are looking at.
    public static func callsigns(in document: ADIFDocument, rows: IndexSet) -> [String] {
        var seen: Set<String> = []
        var ordered: [String] = []

        for row in rows.sorted() where document.records.indices.contains(row) {
            let call = (document.records[row]["CALL"] ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .uppercased()
            guard !call.isEmpty, seen.insert(call).inserted else { continue }
            ordered.append(call)
        }

        return ordered
    }

    /// What would be written, given what QRZ returned.
    ///
    /// `results` is keyed by uppercased callsign, as `callsigns(in:rows:)` produced them.
    /// A row whose callsign is missing from it — never looked up, or looked up and not
    /// found — simply contributes nothing.
    ///
    /// **§6.3 is enforced here.** A field the record already has a non-empty value for is
    /// never proposed, whatever QRZ says about it. That covers the case that matters: an
    /// operator who corrected a name by hand does not get it quietly reverted to the one
    /// on file at QRZ.
    ///
    /// `fields` limits which of `QRZFieldMapping.fields` are considered; `nil` means all
    /// of them.
    public static func proposedFills(in document: ADIFDocument,
                                     rows: IndexSet,
                                     results: [String: QRZCallsign],
                                     fields: Set<String>? = nil) -> [ProposedFill] {
        var fills: [ProposedFill] = []

        for row in rows.sorted() where document.records.indices.contains(row) {
            let record = document.records[row]
            let call = (record["CALL"] ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .uppercased()
            guard let found = results[call] else { continue }

            for (field, value) in QRZFieldMapping.values(from: found) {
                if let fields, !fields.contains(field) { continue }

                // Absent and present-but-empty both count as empty, matching how the
                // rest of the app treats a blank cell.
                let existing = (record[field] ?? "").trimmingCharacters(in: .whitespaces)
                guard existing.isEmpty else { continue }

                fills.append(ProposedFill(row: row, field: field, value: value))
            }
        }

        return fills
    }

    /// The records that result from applying `fills`.
    ///
    /// Routed through `recordBySettingValue` one at a time so a filled field lands where
    /// the file already keeps that column rather than at the end of the record — decision
    /// 14, the same rule that governs typing into a cell. Applying to a working copy
    /// rather than to `document.records` directly is what makes two fills on one row both
    /// survive.
    public static func records(in document: ADIFDocument,
                               applying fills: [ProposedFill]) -> [ADIFRecord] {
        var working = document

        for fill in fills {
            guard working.records.indices.contains(fill.row) else { continue }
            if let updated = working.recordBySettingValue(fill.value,
                                                          forColumn: fill.field,
                                                          inRecordAt: fill.row) {
                working.records[fill.row] = updated
            }
        }

        return working.records
    }
}
