import Foundation

/// The seam between QRZKit and the network.
///
/// Everything above this protocol is ordinary logic the test suite exercises with canned
/// responses (§11). `URLSessionTransport` below is the only implementation that opens a
/// socket, and it is kept deliberately thin so that "what does this app send, and where"
/// can be answered by reading one short file.
public protocol QRZTransport: Sendable {
    /// Fetch a URL's body, or throw. Implementations should not interpret the body —
    /// classifying QRZ's answers is `QRZSession`'s job.
    func get(_ url: URL) async throws -> Data
}

/// The real thing.
///
/// Two configuration choices matter more than they look. The session is **ephemeral**
/// and the request ignores local caches, because the QRZ XML service takes the password
/// as a query parameter: a default `URLSession` would write that URL into an on-disk
/// `URLCache` index, leaving the user's QRZ password sitting in a cache file. Cookies
/// are off for the same reason — there is no state here worth persisting.
public struct URLSessionTransport: QRZTransport {

    private let session: URLSession
    private let timeout: TimeInterval

    public init(timeout: TimeInterval = 15) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = timeout

        // No retries, no background continuation: a lookup the user is watching either
        // answers now or reports why it did not (§10.4).
        configuration.waitsForConnectivity = false

        self.session = URLSession(configuration: configuration)
        self.timeout = timeout
    }

    public func get(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = timeout

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            // `URLError.localizedDescription` is safe; `error` itself carries
            // `failingURL`, which holds the password. Only the description escapes.
            throw QRZError.transportFailure(error.localizedDescription)
        } catch {
            throw QRZError.transportFailure(error.localizedDescription)
        }

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw QRZError.transportFailure(
                "the server answered \(http.statusCode) "
                + "(\(HTTPURLResponse.localizedString(forStatusCode: http.statusCode)))")
        }

        return data
    }
}
