import Foundation

/// A QRZ username and password.
///
/// The password is deliberately awkward to print: `description` redacts it, so a stray
/// interpolation into a log line or an error message cannot leak it (§6.5). Reading it
/// requires asking for `password` by name, which is easy to spot in review.
public struct QRZCredentials: Equatable, Sendable, CustomStringConvertible {

    public let username: String
    public let password: String

    public init(username: String, password: String) {
        self.username = username
        self.password = password
    }

    /// Whether these are worth sending at all. QRZ answers a blank username with a
    /// generic failure, and there is no reason to spend a round trip finding that out.
    public var isUsable: Bool {
        !username.trimmingCharacters(in: .whitespaces).isEmpty && !password.isEmpty
    }

    public var description: String { "QRZCredentials(username: \(username), password: ••••••)" }
}

/// An authenticated conversation with QRZ's XML service.
///
/// An actor because the session key is mutable state shared across whatever concurrency
/// the caller uses, and because two lookups racing to authenticate would otherwise each
/// burn a session — QRZ counts those.
///
/// The key is held in memory only. Quitting the app forgets it, which costs one extra
/// round trip on next launch and means there is no second place a credential-shaped
/// thing can be found on disk.
public actor QRZSession {

    /// QRZ asks clients to identify themselves so they can tell traffic apart.
    public static let defaultAgent = "ADIFEditor1.0"

    public static let defaultBaseURL = URL(string: "https://xmldata.qrz.com/xml/current/")!

    private let credentials: QRZCredentials
    private let transport: QRZTransport
    private let agent: String
    private let baseURL: URL

    private var sessionKey: String?

    public init(credentials: QRZCredentials,
                transport: QRZTransport,
                agent: String = QRZSession.defaultAgent,
                baseURL: URL = QRZSession.defaultBaseURL) {
        self.credentials = credentials
        self.transport = transport
        self.agent = agent
        self.baseURL = baseURL
    }

    // MARK: - Lookup

    /// Look one callsign up, authenticating first if needed.
    ///
    /// A key that has gone stale is renewed once and the lookup retried, because a
    /// session can expire between two rows of the same batch and making the operator
    /// re-run it for that would be silly. Exactly once: if the fresh key is also refused,
    /// something is wrong that retrying will not fix.
    public func lookup(_ callsign: String) async throws -> QRZCallsign {
        let wanted = callsign.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else {
            throw QRZError.callsignNotFound("(blank)")
        }

        do {
            return try await lookup(wanted, usingKey: try await currentKey())
        } catch QRZError.sessionExpired {
            sessionKey = nil
            return try await lookup(wanted, usingKey: try await currentKey())
        }
    }

    /// Forget the session key. The next lookup authenticates again.
    public func signOut() {
        sessionKey = nil
    }

    private func lookup(_ callsign: String, usingKey key: String) async throws -> QRZCallsign {
        let response = try await send(["s": key, "callsign": callsign])

        if let error = response.error {
            throw Self.classify(error, callsign: callsign)
        }

        // QRZ hands back a refreshed key on most responses; keeping it extends the
        // session across a long batch.
        if let refreshed = response.sessionKey { sessionKey = refreshed }

        guard let record = response.callsign else {
            // No callsign block and no error text. QRZ does this for a record the
            // account may not view, and saying so beats reporting an empty success.
            throw QRZError.serviceError(
                "no record was returned for \(callsign), and no reason was given")
        }

        return record
    }

    // MARK: - Authentication

    private func currentKey() async throws -> String {
        if let sessionKey { return sessionKey }

        guard credentials.isUsable else { throw QRZError.notConfigured }

        let response = try await send([
            "username": credentials.username,
            "password": credentials.password,
            "agent": agent
        ])

        if let error = response.error {
            throw Self.classify(error, callsign: nil)
        }

        guard let key = response.sessionKey else {
            throw QRZError.malformedResponse("no session key came back from sign-in")
        }

        sessionKey = key
        return key
    }

    // MARK: - Requests

    private func send(_ parameters: [String: String]) async throws -> QRZResponse {
        let url = try Self.url(base: baseURL, parameters: parameters)
        let data = try await transport.get(url)
        return try QRZResponseParser.parse(data)
    }

    /// QRZ's documented query form separates parameters with `;` rather than `&`.
    ///
    /// Built by hand rather than with `URLComponents`, which would write `&` and
    /// percent-encode the `;` if given one. Values get the strict unreserved set, so a
    /// password containing `;`, `&`, or `+` survives the trip — passwords do contain
    /// those, and getting it wrong would look exactly like a wrong password.
    static func url(base: URL, parameters: [String: String]) throws -> URL {
        // Sorted for a stable, testable string; QRZ does not care about order.
        let query = parameters.sorted { $0.key < $1.key }
            .map { "\($0.key)=\(escape($0.value))" }
            .joined(separator: ";")

        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw QRZError.transportFailure("the QRZ address could not be assembled")
        }
        components.percentEncodedQuery = query

        guard let url = components.url else {
            throw QRZError.transportFailure("the QRZ address could not be assembled")
        }
        return url
    }

    /// RFC 3986's unreserved set. Everything else is escaped, including the `;` and `&`
    /// that would otherwise split one parameter into two.
    private static let unreserved: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()

    private static func escape(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }

    // MARK: - Classifying QRZ's errors

    /// QRZ reports failures as English sentences inside `<Session><Error>`, with no code
    /// to switch on, so this matches on substrings. Deliberately lenient about wording
    /// and deliberately conservative about the result: anything unrecognised becomes
    /// `.serviceError`, which does not stop a batch and shows QRZ's own words to the
    /// operator rather than a guess.
    static func classify(_ message: String, callsign: String?) -> QRZError {
        let text = message.lowercased()

        func mentions(_ needles: String...) -> Bool {
            needles.contains { text.contains($0) }
        }

        if mentions("not found", "no record") {
            return .callsignNotFound(callsign ?? message)
        }
        if mentions("session timeout", "invalid session key", "session does not exist",
                    "invalid session") {
            return .sessionExpired(message)
        }
        if mentions("username/password", "user name or password", "password incorrect",
                    "incorrect password", "invalid user") {
            return .badCredentials(message)
        }
        if mentions("subscription", "not authorized", "not permitted",
                    "does not have permission") {
            return .subscriptionRequired(message)
        }
        return .serviceError(message)
    }
}
