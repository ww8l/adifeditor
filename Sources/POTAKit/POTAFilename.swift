import Foundation
import ADIFKit

/// POTA's output filename convention (§10.2):
///
/// ```
/// CALL@REFERENCE YYYYMMDD.adi
/// W1XYZ@US-1234 20260811.adi
/// ```
public enum POTAFilename {

    /// Builds the filename. Every part is data already in the log; nothing is invented.
    public static func name(callsign: String, park: ParkReference, date: String) -> String {
        let call = sanitized(callsign)
        let reference = sanitized(park.text)

        let stem = date.isEmpty
            ? "\(call)@\(reference)"
            : "\(call)@\(reference) \(date)"

        return stem + ".adi"
    }

    /// The operator's callsign, from `STATION_CALLSIGN` falling back to `OPERATOR`
    /// (§10.2). `nil` when the log carries neither, which is the case where the interface
    /// has to ask.
    public static func callsign(in document: ADIFDocument) -> String? {
        for field in ["STATION_CALLSIGN", "OPERATOR"] {
            for record in document.records {
                if let value = record[field], !value.isEmpty { return value }
            }
        }
        return nil
    }

    /// The earliest `QSO_DATE` in the log.
    ///
    /// Compared as text, which is correct for a fixed-width `YYYYMMDD` and avoids
    /// inventing a date parser that would have to decide what a malformed date means.
    ///
    /// No inference and no disambiguation prompt when a log spans several days (decision
    /// 12): the operator trims the log to one activation first, using sort and delete.
    /// Empty when no QSO carries a date, and the filename simply goes without one.
    public static func earliestDate(in document: ADIFDocument) -> String {
        document.records
            .compactMap { $0["QSO_DATE"] }
            .filter { !$0.isEmpty }
            .min() ?? ""
    }

    /// Replaces characters that cannot appear in a filename.
    ///
    /// A portable callsign like `WW8L/P` is the common case, and a `/` is a path
    /// separator. Substituting rather than stripping keeps the callsign readable, and the
    /// operator can edit the proposed name before anything is written (§10.2).
    ///
    /// Applied again by `POTATargets` to whatever the operator typed there, since a `/`
    /// reaching `appendingPathComponent` writes into a subpath rather than the folder
    /// they chose.
    static func sanitized(_ text: String) -> String {
        String(text.map { character in
            "/:\\".contains(character) ? "-" : character
        })
    }
}
