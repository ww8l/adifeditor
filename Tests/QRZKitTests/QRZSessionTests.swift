import Testing
import Foundation
@testable import QRZKit

/// Authentication, session handling, and how QRZ's failures are classified.
///
/// Every test here runs on `FakeTransport`. Nothing in this file opens a connection,
/// which is §11's rule for this target and the reason the transport is a protocol.
@Suite("QRZ session")
struct QRZSessionTests {

    private let credentials = QRZCredentials(username: "ww8l", password: "hunter2")

    private func session(_ transport: FakeTransport) -> QRZSession {
        QRZSession(credentials: credentials, transport: transport)
    }

    // MARK: - The happy path

    @Test("a lookup authenticates first, then asks")
    func authenticatesThenLooks() async throws {
        let transport = FakeTransport(bodies: [QRZFixtures.session(),
                                               QRZFixtures.callsign()])
        let record = try await session(transport).lookup("W1ABC")

        #expect(record.call == "W1ABC")
        #expect(transport.requestCount == 2)
    }

    @Test("the session key is reused rather than re-earned for every callsign")
    func reusesSessionKey() async throws {
        // QRZ counts sessions. Authenticating once per lookup would be both slow and
        // rude, and on a 66-QSO log it doubles the traffic.
        let transport = FakeTransport(bodies: [QRZFixtures.session(),
                                               QRZFixtures.callsign("W1ABC"),
                                               QRZFixtures.callsign("K2XYZ")])
        let subject = session(transport)

        _ = try await subject.lookup("W1ABC")
        _ = try await subject.lookup("K2XYZ")

        #expect(transport.requestCount == 3, "one sign-in, two lookups")
    }

    @Test("a refreshed key from a lookup is adopted")
    func adoptsRefreshedKey() async throws {
        let transport = FakeTransport(bodies: [
            QRZFixtures.session(key: "first"),
            QRZFixtures.callsign("W1ABC", key: "second"),
            QRZFixtures.callsign("K2XYZ", key: "second")
        ])
        let subject = session(transport)

        _ = try await subject.lookup("W1ABC")
        _ = try await subject.lookup("K2XYZ")

        let lastQuery = try #require(transport.requestedURLs.last?.query)
        #expect(lastQuery.contains("s=second"))
    }

    // MARK: - Expiry

    @Test("an expired session is renewed and the lookup retried once")
    func renewsExpiredSession() async throws {
        // A batch long enough to outlive a session should not make the operator run it
        // again from the start.
        let transport = FakeTransport(bodies: [
            QRZFixtures.session(key: "stale"),
            QRZFixtures.sessionError("Invalid session key"),
            QRZFixtures.session(key: "fresh"),
            QRZFixtures.callsign("W1ABC")
        ])
        let record = try await session(transport).lookup("W1ABC")

        #expect(record.call == "W1ABC")
        #expect(transport.requestCount == 4)
    }

    @Test("a session that will not renew fails instead of retrying forever")
    func expiryRetriesOnlyOnce() async throws {
        // Every response says the key is stale. Without the once-only rule this recurses
        // until the process dies — §6.4's "never crash" includes never hanging.
        let transport = FakeTransport(body: QRZFixtures.sessionError("Session Timeout"))

        await #expect(throws: QRZError.sessionExpired("Session Timeout")) {
            try await session(transport).lookup("W1ABC")
        }
        #expect(transport.requestCount <= 4, "not an unbounded retry loop")
    }

    // MARK: - Failures

    @Test("a bad password is reported and not retried")
    func badCredentialsAreFinal() async throws {
        // Retrying a rejected password is how an account gets locked out.
        let transport = FakeTransport(body: QRZFixtures.sessionError("Username/password incorrect"))

        await #expect(throws: QRZError.badCredentials("Username/password incorrect")) {
            try await session(transport).lookup("W1ABC")
        }
        #expect(transport.requestCount == 1)
    }

    @Test("a callsign QRZ has never heard of is reported as that")
    func notFound() async throws {
        let transport = FakeTransport(bodies: [QRZFixtures.session(),
                                               QRZFixtures.sessionError("Not found: ZZ9ZZZ")])

        await #expect(throws: QRZError.callsignNotFound("ZZ9ZZZ")) {
            try await session(transport).lookup("ZZ9ZZZ")
        }
    }

    @Test("a lapsed subscription is distinguished from a bad password")
    func subscriptionRequired() async throws {
        // Different problem, different fix: one means re-type the password, the other
        // means go and pay QRZ.
        let transport = FakeTransport(bodies: [
            QRZFixtures.session(),
            QRZFixtures.sessionError("A subscription is required to access this data")
        ])

        await #expect(throws: QRZError.subscriptionRequired(
            "A subscription is required to access this data")) {
            try await session(transport).lookup("W1ABC")
        }
    }

    @Test("wording QRZKit does not recognise is passed through, not guessed at")
    func unknownErrorsPassThrough() {
        // QRZ adds messages without warning. Inventing a friendlier diagnosis would hide
        // the only useful information the operator has.
        #expect(QRZSession.classify("Cannot connect to the database", callsign: "W1ABC")
                == .serviceError("Cannot connect to the database"))
    }

    @Test("a response with neither a record nor an error is not a silent success")
    func emptySuccessIsAnError() async throws {
        let transport = FakeTransport(bodies: [
            QRZFixtures.session(),
            "<QRZDatabase><Session><Key>k</Key></Session></QRZDatabase>"
        ])

        await #expect(throws: QRZError.self) {
            try await session(transport).lookup("W1ABC")
        }
    }

    @Test("a transport failure reaches the caller as one")
    func transportFailure() async throws {
        let transport = FakeTransport(responses: [
            .failure(QRZError.transportFailure("The Internet connection appears to be offline."))
        ])

        await #expect(throws: QRZError.transportFailure(
            "The Internet connection appears to be offline.")) {
            try await session(transport).lookup("W1ABC")
        }
    }

    // MARK: - Not asking at all

    @Test("no credentials means no request")
    func notConfiguredMakesNoRequest() async throws {
        // §6.5: a fresh install opens no connections. This is that guarantee, at the one
        // place it can be checked.
        let transport = FakeTransport(body: QRZFixtures.session())
        let subject = QRZSession(credentials: QRZCredentials(username: "", password: ""),
                                 transport: transport)

        await #expect(throws: QRZError.notConfigured) {
            try await subject.lookup("W1ABC")
        }
        #expect(transport.requestCount == 0)
    }

    @Test("a whitespace-only username counts as no credentials")
    func blankUsernameIsNotConfigured() async throws {
        let transport = FakeTransport(body: QRZFixtures.session())
        let subject = QRZSession(credentials: QRZCredentials(username: "   ", password: "x"),
                                 transport: transport)

        await #expect(throws: QRZError.notConfigured) {
            try await subject.lookup("W1ABC")
        }
        #expect(transport.requestCount == 0)
    }

    @Test("a username with no password counts as no credentials")
    func blankPasswordIsNotConfigured() async throws {
        // The mirror of the test above, and not redundant with it: both of the others
        // fail on the username, so nothing exercised the password half and deleting it
        // from `isUsable` survived the whole suite. Someone who typed a username into
        // Settings and no password would spend a real request against QRZ on credentials
        // that cannot work — §6.5's one bullet the OS no longer enforces.
        let transport = FakeTransport(body: QRZFixtures.session())
        let subject = QRZSession(credentials: QRZCredentials(username: "ww8l", password: ""),
                                 transport: transport)

        await #expect(throws: QRZError.notConfigured) {
            try await subject.lookup("W1ABC")
        }
        #expect(transport.requestCount == 0)
    }

    @Test("a blank callsign is refused before a request is spent on it")
    func blankCallsign() async throws {
        let transport = FakeTransport(body: QRZFixtures.session())

        await #expect(throws: QRZError.callsignNotFound("(blank)")) {
            try await session(transport).lookup("   ")
        }
        #expect(transport.requestCount == 0)
    }

    @Test("signing out forces the next lookup to authenticate again")
    func signOutForgetsKey() async throws {
        let transport = FakeTransport(bodies: [QRZFixtures.session(),
                                               QRZFixtures.callsign(),
                                               QRZFixtures.session(),
                                               QRZFixtures.callsign()])
        let subject = session(transport)

        _ = try await subject.lookup("W1ABC")
        await subject.signOut()
        _ = try await subject.lookup("W1ABC")

        #expect(transport.requestCount == 4)
    }

    // MARK: - The query, and what must not be in it

    @Test("parameters are separated the way QRZ documents")
    func usesSemicolonSeparators() throws {
        let url = try QRZSession.url(base: QRZSession.defaultBaseURL,
                                     parameters: ["s": "key", "callsign": "W1ABC"])

        #expect(url.absoluteString
                == "https://xmldata.qrz.com/xml/current/?callsign=W1ABC;s=key")
    }

    @Test("a password containing separators survives the trip")
    func escapesPasswordSpecials() throws {
        // A password of "a;b&c=d" split into extra parameters would reach QRZ as the
        // wrong password, and the operator would be told their password is wrong while
        // looking at the correct one.
        let url = try QRZSession.url(base: QRZSession.defaultBaseURL,
                                     parameters: ["password": "a;b&c=d e+f"])
        let query = try #require(url.query(percentEncoded: true))

        #expect(query == "password=a%3Bb%26c%3Dd%20e%2Bf")
        #expect(!query.dropFirst("password=".count).contains(";"))
    }

    @Test("a unicode password is encoded rather than dropped")
    func escapesUnicodePassword() throws {
        let url = try QRZSession.url(base: QRZSession.defaultBaseURL,
                                     parameters: ["password": "påssword"])

        #expect(url.query(percentEncoded: true) == "password=p%C3%A5ssword")
    }

    @Test("no error message anywhere contains the password")
    func errorsNeverLeakThePassword() async {
        // The password travels as a query parameter, so anything that quotes a URL leaks
        // it — into an alert, a log, a crash report. §6.5 says credentials never appear
        // in any of those, and this is the check that it stays true.
        let secret = "correct-horse-battery-staple"
        let subject = QRZSession(
            credentials: QRZCredentials(username: "ww8l", password: secret),
            transport: FakeTransport(responses: [
                .failure(QRZError.transportFailure("could not connect"))
            ]))

        do {
            _ = try await subject.lookup("W1ABC")
            Issue.record("the lookup should have failed")
        } catch let error as QRZError {
            #expect(!"\(error)".contains(secret))
            #expect(!(error.errorDescription ?? "").contains(secret))
        } catch {
            Issue.record("unexpected error type")
        }
    }

    @Test("credentials redact their password when printed")
    func credentialsRedactWhenPrinted() {
        // The likeliest leak is not a considered decision but a stray interpolation.
        let credentials = QRZCredentials(username: "ww8l", password: "hunter2")

        #expect(!"\(credentials)".contains("hunter2"))
        #expect("\(credentials)".contains("ww8l"))
        #expect(credentials.password == "hunter2", "though it is still readable on purpose")
    }

    // MARK: - Which failures end a batch

    @Test("only failures that would repeat stop a batch")
    func batchStoppingClassification() {
        // A callsign QRZ lacks says nothing about the next one. A bad password says
        // everything about the next eighty.
        #expect(QRZError.callsignNotFound("ZZ9ZZZ").stopsBatch == false)
        #expect(QRZError.serviceError("odd").stopsBatch == false)
        #expect(QRZError.malformedResponse("odd").stopsBatch == false)

        #expect(QRZError.badCredentials("no").stopsBatch)
        #expect(QRZError.subscriptionRequired("no").stopsBatch)
        #expect(QRZError.transportFailure("offline").stopsBatch)
        #expect(QRZError.notConfigured.stopsBatch)
    }
}
