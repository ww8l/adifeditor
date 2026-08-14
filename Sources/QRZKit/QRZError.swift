import Foundation

/// What can go wrong talking to QRZ.
///
/// Every case carries enough to tell the operator which callsign failed and what to do
/// about it, and none of them carry a URL. That is deliberate: the QRZ XML service takes
/// the password as a query parameter, so any error that quoted the request it came from
/// would put the user's QRZ password into an alert, a log, or a crash report. §6.5's
/// "credentials never in a log" is enforced by simply never having the string here.
public enum QRZError: Error, Equatable, Sendable {

    /// No username and password have been entered yet. Not a failure so much as the
    /// resting state of a fresh install (§6.5).
    case notConfigured

    /// QRZ rejected the username or password. Retrying will not help and the app must
    /// not retry, since repeated bad attempts are how an account gets locked.
    case badCredentials(String)

    /// The account authenticated but is not entitled to the data — an expired
    /// subscription, or a lookup the free tier does not cover.
    case subscriptionRequired(String)

    /// The session key went stale. Recoverable: authenticate again and retry once.
    /// Callers should not surface this — if it reaches the user, the retry also failed.
    case sessionExpired(String)

    /// QRZ has no record of this callsign. Expected in normal use — a special event
    /// call, a club station, a busted decode — and not a reason to abandon a batch.
    case callsignNotFound(String)

    /// QRZ answered, but with something this code does not recognise. The message is
    /// QRZ's own text, passed through rather than interpreted, because the service adds
    /// new ones without warning and inventing a friendlier wording would only obscure it.
    case serviceError(String)

    /// The response was not the XML this code knows how to read — a truncated body, an
    /// HTML error page from a proxy, a captive portal.
    case malformedResponse(String)

    /// The request never completed: no network, DNS failure, timeout, TLS refusal.
    /// Carries a description rather than the underlying error so the type stays
    /// `Equatable` and, more to the point, so a `URLError` cannot drag the failing URL
    /// (and the password in it) along with it.
    case transportFailure(String)
}

extension QRZError: LocalizedError {

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "No QRZ credentials have been entered."
        case .badCredentials(let message):
            return "QRZ rejected the username or password: \(message)"
        case .subscriptionRequired(let message):
            return "This lookup needs an active QRZ XML subscription: \(message)"
        case .sessionExpired(let message):
            return "The QRZ session expired and could not be renewed: \(message)"
        case .callsignNotFound(let callsign):
            return "QRZ has no record of \(callsign)."
        case .serviceError(let message):
            return "QRZ reported: \(message)"
        case .malformedResponse(let detail):
            return "QRZ's response could not be read: \(detail)"
        case .transportFailure(let detail):
            return "Could not reach QRZ: \(detail)"
        }
    }

    /// Whether a whole batch should stop here.
    ///
    /// A callsign QRZ has never heard of says nothing about the next callsign, so the
    /// batch carries on and reports it at the end. Bad credentials, a lapsed
    /// subscription, or a dead network will fail identically for every remaining row,
    /// and hammering the service with another eighty doomed requests is both rude and a
    /// good way to get rate-limited.
    public var stopsBatch: Bool {
        switch self {
        case .callsignNotFound, .serviceError, .malformedResponse:
            return false
        case .notConfigured, .badCredentials, .subscriptionRequired, .sessionExpired,
             .transportFailure:
            return true
        }
    }
}
