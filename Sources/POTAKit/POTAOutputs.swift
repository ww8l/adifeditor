import Foundation
import ADIFKit

/// Writing the split's files, and saying afterwards exactly which of them exist.
///
/// A loop that writes files and stops at the first error leaves the operator worse off
/// than one that never started: some of the set is on disk, the rest is not, and the
/// error a `Data.write` throws names only the file it was on. The next move after a
/// failed split is to run it again, which then meets the "already exists" prompt for
/// files the operator does not know they made.
///
/// So the outcome is a value rather than a `throws`, and it distinguishes three groups —
/// the same shape `QRZBatch` reports for the same reason. It lives in POTAKit rather
/// than beside the sheet because what got written is a fact about the operation, not
/// about how to phrase it; the wording is the app layer's.
///
/// Deliberately *not* an all-or-nothing set staged in a temporary directory. Moving a
/// finished set into place trades one partial state for another — a move can fail
/// halfway too, and a move over a file the operator agreed to replace cannot be rolled
/// back at all, because the file it replaced is gone. Writing straight through and being
/// honest about where it stopped is the smaller promise, and it is one that can be kept.
public enum POTAOutputs {

    /// What happened, in enough detail to tell the operator what is on disk.
    public struct Outcome {
        /// Files that exist now, in the order they were written.
        public let written: [URL]
        /// The file the run stopped on, and why. `nil` when everything was written.
        public let failure: Failure?
        /// Files never attempted, because the failure stopped the run before them.
        public let notAttempted: [URL]

        public struct Failure {
            public let target: URL
            public let error: Error
        }

        public var succeeded: Bool { failure == nil }
    }

    /// Writes each document to the target in the same position, stopping at the first
    /// failure.
    ///
    /// Stopping rather than pressing on: the failures this meets are conditions of the
    /// destination — a full volume, a folder that turns out not to be writable — so the
    /// remaining writes would fail the same way, and reporting one cause beats reporting
    /// the same cause five times.
    public static func write(_ documents: [ADIFDocument], to targets: [URL]) -> Outcome {
        var written: [URL] = []

        for (index, target) in targets.enumerated() {
            guard index < documents.count else { break }
            do {
                try ADIFWriter.write(documents[index]).write(to: target, options: .atomic)
                written.append(target)
            } catch {
                return Outcome(written: written,
                               failure: Outcome.Failure(target: target, error: error),
                               notAttempted: Array(targets[(index + 1)...]))
            }
        }

        return Outcome(written: written, failure: nil, notAttempted: [])
    }
}
