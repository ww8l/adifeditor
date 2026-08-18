import Testing
import Foundation
@testable import QRZKit

/// Looking up a whole selection.
///
/// The batch's job is to be undramatic: it never throws, it reports what it got and what
/// it did not, and it stops asking when the answer will obviously be the same for every
/// remaining callsign.
@Suite("QRZ batch")
struct QRZBatchTests {

    private let credentials = QRZCredentials(username: "ww8l", password: "hunter2")

    private func session(_ transport: FakeTransport) -> QRZSession {
        QRZSession(credentials: credentials, transport: transport)
    }

    /// No pause: the politeness delay is real behaviour but would make the suite crawl.
    private func run(_ callsigns: [String], on transport: FakeTransport) async -> QRZBatchResult {
        await QRZBatch.lookUp(callsigns, using: session(transport), pause: .zero)
    }

    @Test("every callsign that answers is collected")
    func collectsResults() async {
        let transport = FakeTransport(bodies: [QRZFixtures.session(),
                                               QRZFixtures.callsign("W1ABC"),
                                               QRZFixtures.callsign("K2XYZ")])
        let result = await run(["W1ABC", "K2XYZ"], on: transport)

        #expect(Set(result.found.keys) == ["W1ABC", "K2XYZ"])
        #expect(result.failures.isEmpty)
        #expect(result.stoppedEarly == nil)
        #expect(result.notAttempted.isEmpty)
    }

    @Test("a callsign QRZ lacks is recorded and the batch carries on")
    func continuesPastNotFound() async {
        // The common case in a POTA log: a special event call or a busted decode sitting
        // in the middle of sixty good ones.
        let transport = FakeTransport(bodies: [
            QRZFixtures.session(),
            QRZFixtures.sessionError("Not found: ZZ9ZZZ"),
            QRZFixtures.callsign("W1ABC")
        ])
        let result = await run(["ZZ9ZZZ", "W1ABC"], on: transport)

        #expect(result.found.keys.contains("W1ABC"))
        #expect(result.failures == [QRZLookupFailure(callsign: "ZZ9ZZZ",
                                                     error: .callsignNotFound("ZZ9ZZZ"))])
        #expect(result.stoppedEarly == nil)
    }

    @Test("a failure that would repeat stops the batch and says what was skipped")
    func stopsOnFatalFailure() async {
        // Eighty more requests against a dead network would waste the operator's time and
        // tell them nothing new.
        let transport = FakeTransport(responses: [
            .success(Data(QRZFixtures.session().utf8)),
            .success(Data(QRZFixtures.callsign("W1ABC").utf8)),
            .failure(QRZError.transportFailure("offline"))
        ])
        let result = await run(["W1ABC", "K2XYZ", "N3DEF"], on: transport)

        #expect(result.found.keys.contains("W1ABC"), "the work already done survives")
        #expect(result.stoppedEarly == .transportFailure("offline"))
        #expect(result.notAttempted == ["K2XYZ", "N3DEF"])
    }

    @Test("a bad password stops the batch on the first callsign")
    func stopsOnBadCredentials() async {
        let transport = FakeTransport(body: QRZFixtures.sessionError("Username/password incorrect"))
        let result = await run(["W1ABC", "K2XYZ"], on: transport)

        #expect(result.found.isEmpty)
        #expect(result.stoppedEarly == .badCredentials("Username/password incorrect"))
        #expect(result.notAttempted == ["W1ABC", "K2XYZ"])
        #expect(transport.requestCount == 1, "and does not keep trying the password")
    }

    @Test("a rate limit stops the batch instead of spending the rest of it")
    func stopsOnRateLimit() async {
        // The pause between requests exists to avoid being rate-limited; carrying on
        // through one is the same mistake at a larger scale, and it is what makes a
        // temporary block a longer one.
        let transport = FakeTransport(responses: [
            .success(Data(QRZFixtures.session().utf8)),
            .success(Data(QRZFixtures.callsign("W1ABC").utf8)),
            .success(Data(QRZFixtures.sessionError("Excessive queries in a 24 hour period").utf8))
        ])
        let result = await run(["W1ABC", "K2XYZ", "N3DEF"], on: transport)

        #expect(result.found.keys.contains("W1ABC"), "the work already done survives")
        #expect(result.stoppedEarly == .rateLimited("Excessive queries in a 24 hour period"))
        #expect(result.notAttempted == ["K2XYZ", "N3DEF"])
    }

    @Test("the batch never throws, whatever happens")
    func neverThrows() async {
        // §6.4. The caller has partial results to show and a reason to display; there is
        // nothing here worth unwinding the stack for.
        let transport = FakeTransport(responses: [
            .failure(QRZError.transportFailure("offline"))
        ])
        let result = await run(["W1ABC"], on: transport)

        #expect(result.stoppedEarly != nil)
    }

    @Test("an error from outside QRZKit is reported, not trapped on")
    func handlesForeignErrors() async {
        struct Surprise: Error {}
        let transport = FakeTransport(responses: [.failure(Surprise())])
        let result = await run(["W1ABC"], on: transport)

        #expect(result.stoppedEarly != nil)
        #expect(result.found.isEmpty)
    }

    @Test("cancelling keeps what was already found")
    func cancellationKeepsPartialResults() async {
        let transport = FakeTransport(bodies: [QRZFixtures.session(),
                                               QRZFixtures.callsign("W1ABC")])
        let subject = session(transport)

        let task = Task {
            await QRZBatch.lookUp(["W1ABC", "K2XYZ", "N3DEF"],
                                  using: subject,
                                  pause: .milliseconds(50))
        }

        // Long enough for the first lookup, short enough to land inside the pause before
        // the second.
        try? await Task.sleep(for: .milliseconds(20))
        task.cancel()

        let result = await task.value
        #expect(result.wasCancelled)
        #expect(!result.notAttempted.isEmpty)
    }

    @Test("progress is reported once per callsign")
    func reportsProgress() async {
        let transport = FakeTransport(bodies: [QRZFixtures.session(),
                                               QRZFixtures.callsign("W1ABC"),
                                               QRZFixtures.callsign("K2XYZ")])

        let counter = Counter()
        _ = await QRZBatch.lookUp(["W1ABC", "K2XYZ"],
                                  using: session(transport),
                                  pause: .zero) { completed, total in
            counter.record(completed: completed, total: total)
        }

        #expect(counter.completions == [1, 2])
        #expect(counter.total == 2)
    }

    @Test("an empty selection makes no requests at all")
    func emptySelection() async {
        let transport = FakeTransport(body: QRZFixtures.session())
        let result = await run([], on: transport)

        #expect(transport.requestCount == 0)
        #expect(result.found.isEmpty)
        #expect(result.stoppedEarly == nil)
    }
}

/// Collects progress callbacks from whatever executor the batch is running on.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [Int] = []
    private var lastTotal = 0

    func record(completed: Int, total: Int) {
        lock.withLock {
            seen.append(completed)
            lastTotal = total
        }
    }

    var completions: [Int] { lock.withLock { seen } }
    var total: Int { lock.withLock { lastTotal } }
}
