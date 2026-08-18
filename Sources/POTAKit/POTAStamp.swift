import Foundation
import ADIFKit

/// Writing park references into a log.
///
/// Two operations that are really one: stamping is the single-park case and splitting is
/// the many-park case, and §10.2 has the interface flow from one into the other.
public enum POTAStamp {

    /// The field POTA's uploader reads the park reference from.
    public static let referenceField = "MY_SIG_INFO"

    /// The optional companion field naming the program. Off by default (§10.2) — POTA can
    /// generally infer it — and controlled by a preference once preferences exist (M4).
    public static let programField = "MY_SIG"
    public static let programValue = "POTA"

    /// The result of stamping: the new document, and what it did.
    public struct Outcome: Equatable, Sendable {
        /// QSOs that had no reference and now have one.
        public var filled: Int

        /// QSOs left exactly as they were because they already carried a reference.
        /// §6.3: an automated tool does not overwrite a value that is already there.
        public var preserved: Int

        public var document: ADIFDocument
    }

    /// Fills the park reference into every QSO that does not already have one.
    ///
    /// Additive, never destructive (§6.3). A QSO that already carries a `MY_SIG_INFO` is
    /// left alone — including one whose reference disagrees with the park being stamped,
    /// because the operator put it there and only the operator should change it.
    public static func stamp(
        _ document: ADIFDocument,
        with park: ParkReference,
        alsoWriteProgramField writeProgram: Bool = false
    ) -> Outcome {
        var result = document
        var filled = 0
        var preserved = 0

        for index in result.records.indices {
            if result.records[index].isEmpty(referenceField) {
                if let stamped = result.recordBySettingValue(park.text,
                                                             forColumn: referenceField,
                                                             inRecordAt: index) {
                    result.records[index] = stamped
                    filled += 1
                }
            } else {
                preserved += 1
            }

            guard writeProgram, result.records[index].isEmpty(programField) else { continue }
            if let tagged = result.recordBySettingValue(programValue,
                                                        forColumn: programField,
                                                        inRecordAt: index) {
                result.records[index] = tagged
            }
        }

        return Outcome(filled: filled, preserved: preserved, document: result)
    }

    /// One output file per park: every QSO appears in every file, because being inside
    /// three parks means each contact counts for all three (§10.2).
    ///
    /// The source document is never modified — the caller gets new documents and §6.1
    /// holds by construction.
    ///
    /// This is the one place §6.3's "never overwrite" is permitted to bend, since deriving
    /// per-park files necessarily writes a different reference into each. It is not
    /// allowed to be silent: `recordsWithExistingReference` tells the caller how many QSOs
    /// already carry a reference so it can ask before replacing them.
    public static func split(
        _ document: ADIFDocument,
        into parks: [ParkReference],
        replacingExistingReferences replace: Bool,
        alsoWriteProgramField writeProgram: Bool = false
    ) -> [(park: ParkReference, document: ADIFDocument)] {
        parks.map { park in
            var source = document

            // Replacing writes *through* the existing field rather than clearing it and
            // letting `stamp` add it back. The shorter version — clear, then fill —
            // reused one code path, but clearing removed the last copy of the field from
            // the document, so what came back took the normalized spelling and landed at
            // the end of the record: a file that said `<my_sig_info:7>US-1111` in the
            // middle of each QSO got `<MY_SIG_INFO:7>US-2222` appended last (decision 3).
            // Only the derived files are affected and POTA reads the name
            // case-insensitively, but an output that does not look like its input is not
            // what this app hands anyone.
            if replace {
                for index in source.records.indices where !source.records[index].isEmpty(referenceField) {
                    if let replaced = source.recordBySettingValue(park.text,
                                                                  forColumn: referenceField,
                                                                  inRecordAt: index) {
                        source.records[index] = replaced
                    }
                }
            }

            let outcome = stamp(source, with: park, alsoWriteProgramField: writeProgram)
            return (park: park, document: outcome.document)
        }
    }

    /// How many QSOs already carry a park reference. The number §6.3 requires the split to
    /// put in front of the operator before it replaces anything.
    public static func recordsWithExistingReference(in document: ADIFDocument) -> Int {
        document.records.filter { !$0.isEmpty(referenceField) }.count
    }
}
