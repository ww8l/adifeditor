import Foundation
import QRZKit

/// Everything the app remembers between launches.
///
/// Small on purpose. The username, the POTA program-field switch, and which QRZ fields to
/// fill are ordinary preferences. The QRZ **password** is not here — it is in the
/// Keychain (§6.5), and the only way to it is `credentials`, which fetches it on demand
/// rather than caching it in a property someone could later print.
enum Preferences {

    /// One service name for the app's Keychain items. Matches the bundle identifier
    /// because that is what a user scanning Keychain Access will look for.
    static let keychainService = "com.ww8l.adifeditor.qrz"

    private enum Key {
        static let qrzUsername = "QRZUsername"
        static let qrzFields = "QRZFields"
        static let writeMySigField = "WriteMySigField"
    }

    // MARK: - QRZ

    /// The QRZ account name. Not a secret, so an ordinary default.
    static var qrzUsername: String {
        get { UserDefaults.standard.string(forKey: Key.qrzUsername) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: Key.qrzUsername) }
    }

    /// The credentials, assembled from both stores, or `nil` when the app has none.
    ///
    /// `nil` is the resting state §6.5 promises: a fresh install returns nothing here,
    /// and a caller treats it as "the lookup is unavailable" rather than as an error.
    ///
    /// A Keychain that *refuses* is a third state and throws, because it is not the same
    /// news. This used to swallow it into `nil`, so a locked Keychain told the user "no
    /// QRZ credentials have been entered" — twice, once here and again on the Settings
    /// status line — and sent them to retype a password they already had. §6.4 asks for a
    /// diagnostic that names the problem, and that named a different one.
    ///
    /// `readPassword` exists so the refusing case can be exercised: the real Keychain
    /// cannot be made to fail on demand, and this is the branch that was wrong.
    static func credentials(
        readPassword: (_ account: String, _ service: String) throws -> String?
            = Keychain.password
    ) throws -> QRZCredentials? {
        let username = qrzUsername
        guard !username.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }

        guard let password = try readPassword(username, keychainService),
              !password.isEmpty else { return nil }

        return QRZCredentials(username: username, password: password)
    }

    /// Whether QRZ credentials are configured. Reads the password to find out — there is
    /// no cheaper answer, since a username on file with nothing in the Keychain behind it
    /// is not a configured account — and reports a refusing Keychain as not configured,
    /// which is why the two callers that have somewhere to put an error use
    /// `credentials()` instead.
    static var hasQRZCredentials: Bool { (try? credentials()) != nil }

    static func setQRZCredentials(username: String, password: String) throws {
        let trimmed = username.trimmingCharacters(in: .whitespaces)

        // Changing the username orphans the old Keychain item, which would otherwise sit
        // there holding a password for an account the app no longer uses.
        let previous = qrzUsername
        if !previous.isEmpty && previous != trimmed {
            try? Keychain.delete(account: previous, service: keychainService)
        }

        try Keychain.store(password, account: trimmed, service: keychainService)
        qrzUsername = trimmed
    }

    /// Forget the account entirely, returning the app to the state a fresh install is in.
    static func clearQRZCredentials() throws {
        let username = qrzUsername
        guard !username.isEmpty else { return }

        try Keychain.delete(account: username, service: keychainService)
        qrzUsername = ""
    }

    /// Which ADIF fields a lookup may fill. Defaults to all of them; the operator narrows
    /// it in the lookup sheet and the choice sticks for next time.
    static var qrzFields: Set<String> {
        get {
            guard let stored = UserDefaults.standard.array(forKey: Key.qrzFields) as? [String]
            else { return Set(QRZFieldMapping.fields) }
            return Set(stored)
        }
        set {
            UserDefaults.standard.set(Array(newValue).sorted(), forKey: Key.qrzFields)
        }
    }

    // MARK: - POTA

    /// Whether the POTA output also carries `MY_SIG` = `POTA` (§10.2). Off by default,
    /// and until now reachable only by setting the default by hand.
    static var writeMySigField: Bool {
        get { UserDefaults.standard.bool(forKey: Key.writeMySigField) }
        set { UserDefaults.standard.set(newValue, forKey: Key.writeMySigField) }
    }
}
