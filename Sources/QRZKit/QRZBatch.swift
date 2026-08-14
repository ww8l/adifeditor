import Foundation

/// One callsign that could not be looked up, and why.
public struct QRZLookupFailure: Equatable, Sendable {
    public let callsign: String
    public let error: QRZError

    public init(callsign: String, error: QRZError) {
        self.callsign = callsign
        self.error = error
    }
}

/// What a batch of lookups produced.
///
/// Everything is reported, including the partial case: `found` holds what came back,
/// `failures` names each callsign that did not and why, and `stoppedEarly` is set when
/// something went wrong that would have failed identically for every remaining callsign.
public struct QRZBatchResult: Equatable, Sendable {

    /// Keyed by uppercased callsign, ready for `QRZLookup.proposedFills`.
    public let found: [String: QRZCallsign]

    /// Callsigns that failed individually — almost always "QRZ has no record of this".
    public let failures: [QRZLookupFailure]

    /// Set when the batch gave up: bad credentials, a lapsed subscription, a dead
    /// network. `notAttempted` then holds what never got a request.
    public let stoppedEarly: QRZError?

    /// Callsigns skipped because the batch stopped or the operator cancelled.
    public let notAttempted: [String]

    /// Whether the batch was cancelled rather than finishing or failing.
    public let wasCancelled: Bool

    public init(found: [String: QRZCallsign],
                failures: [QRZLookupFailure],
                stoppedEarly: QRZError?,
                notAttempted: [String],
                wasCancelled: Bool) {
        self.found = found
        self.failures = failures
        self.stoppedEarly = stoppedEarly
        self.notAttempted = notAttempted
        self.wasCancelled = wasCancelled
    }
}

/// Looking up many callsigns.
///
/// **Never throws.** A batch that hits a dead network after forty successful lookups
/// still hands back those forty along with the reason it stopped, and the caller decides
/// what to do. Throwing would discard work the operator already waited for, and §10.4's
/// "does not half-fill the log" is satisfied by applying the proposals as one edit — not
/// by pretending the successful half never happened.
public enum QRZBatch {

    /// Requests are made one at a time with a pause between them.
    ///
    /// QRZ's terms discourage rapid bulk querying, and a hundred parallel requests on one
    /// session key is the shape of traffic that gets an account blocked. Sequential and
    /// slightly slow is the right citizen here; a 66-QSO log costs a few seconds.
    public static let defaultPause: Duration = .milliseconds(100)

    /// Look each callsign up in turn.
    ///
    /// - Parameter progress: called after each callsign with (completed, total). Runs on
    ///   whatever executor the batch is on, so a caller updating a window should hop to
    ///   the main actor itself.
    public static func lookUp(_ callsigns: [String],
                              using session: QRZSession,
                              pause: Duration = QRZBatch.defaultPause,
                              progress: (@Sendable (Int, Int) -> Void)? = nil) async
                              -> QRZBatchResult {
        var found: [String: QRZCallsign] = [:]
        var failures: [QRZLookupFailure] = []

        for (index, callsign) in callsigns.enumerated() {

            // The operator can close the sheet on a long batch. Everything gathered so
            // far still comes back.
            if Task.isCancelled {
                return QRZBatchResult(found: found,
                                      failures: failures,
                                      stoppedEarly: nil,
                                      notAttempted: Array(callsigns[index...]),
                                      wasCancelled: true)
            }

            do {
                found[callsign] = try await session.lookup(callsign)
            } catch let error as QRZError where !error.stopsBatch {
                failures.append(QRZLookupFailure(callsign: callsign, error: error))
            } catch let error as QRZError {
                return QRZBatchResult(found: found,
                                      failures: failures,
                                      stoppedEarly: error,
                                      notAttempted: Array(callsigns[index...]),
                                      wasCancelled: false)
            } catch {
                // Nothing else should reach here — `QRZSession` converts everything —
                // but §6.4 says never crash, and an unclassified failure is still a
                // failure worth reporting rather than trapping on.
                return QRZBatchResult(
                    found: found,
                    failures: failures,
                    stoppedEarly: .transportFailure(error.localizedDescription),
                    notAttempted: Array(callsigns[index...]),
                    wasCancelled: false)
            }

            progress?(index + 1, callsigns.count)

            if pause > .zero && index < callsigns.count - 1 {
                try? await Task.sleep(for: pause)
            }
        }

        return QRZBatchResult(found: found,
                              failures: failures,
                              stoppedEarly: nil,
                              notAttempted: [],
                              wasCancelled: false)
    }
}
