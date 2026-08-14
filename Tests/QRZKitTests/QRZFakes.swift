import Foundation
@testable import QRZKit

/// A `QRZTransport` that answers from a script instead of a socket.
///
/// §11's rule for this target is that the suite never opens a connection. This is how
/// that is kept true: every test builds a session on one of these, and nothing in
/// `Tests/QRZKitTests` references `URLSessionTransport` at all.
///
/// Records every URL it was asked for, which is what lets the query-building and
/// credential-handling tests check what *would* have gone over the wire.
final class FakeTransport: QRZTransport, @unchecked Sendable {

    /// Answers in order. The last one repeats once the script runs out, so a test that
    /// only cares about the first two responses does not have to pad the rest.
    private let responses: [Result<Data, Error>]
    private let lock = NSLock()
    private var callCount = 0
    private var urls: [URL] = []

    init(responses: [Result<Data, Error>]) {
        self.responses = responses
    }

    convenience init(bodies: [String]) {
        self.init(responses: bodies.map { .success(Data($0.utf8)) })
    }

    convenience init(body: String) {
        self.init(bodies: [body])
    }

    var requestCount: Int {
        lock.withLock { callCount }
    }

    var requestedURLs: [URL] {
        lock.withLock { urls }
    }

    func get(_ url: URL) async throws -> Data {
        let response: Result<Data, Error> = lock.withLock {
            urls.append(url)
            let index = min(callCount, responses.count - 1)
            callCount += 1
            return responses.isEmpty ? .success(Data()) : responses[index]
        }
        return try response.get()
    }
}

/// QRZ's responses, in the shapes the service documents.
///
/// Hand-built rather than captured — see §11. Kept in one place so a real capture can
/// replace them wholesale later.
enum QRZFixtures {

    static func session(key: String = "3bd4a1e6f8c0d2b5a7e9f1c3d5b7a9e1") -> String {
        """
        <?xml version="1.0" encoding="utf-8" ?>
        <QRZDatabase version="1.34" xmlns="http://xmldata.qrz.com">
          <Session>
            <Key>\(key)</Key>
            <Count>127</Count>
            <SubExp>Tue Dec 31 23:59:59 2026</SubExp>
            <GMTime>Fri Aug 14 18:22:41 2026</GMTime>
          </Session>
        </QRZDatabase>
        """
    }

    static func sessionError(_ message: String) -> String {
        """
        <?xml version="1.0" encoding="utf-8" ?>
        <QRZDatabase version="1.34" xmlns="http://xmldata.qrz.com">
          <Session>
            <Error>\(message)</Error>
            <GMTime>Fri Aug 14 18:22:41 2026</GMTime>
          </Session>
        </QRZDatabase>
        """
    }

    /// A complete US record, the common case for a POTA log.
    static func callsign(_ call: String = "W1ABC",
                         key: String = "3bd4a1e6f8c0d2b5a7e9f1c3d5b7a9e1") -> String {
        """
        <?xml version="1.0" encoding="utf-8" ?>
        <QRZDatabase version="1.34" xmlns="http://xmldata.qrz.com">
          <Callsign>
            <call>\(call)</call>
            <fname>John Q</fname>
            <name>Public</name>
            <name_fmt>John Q Public</name_fmt>
            <addr1>123 Main Street</addr1>
            <addr2>Springfield</addr2>
            <state>MA</state>
            <zip>01103</zip>
            <country>United States</country>
            <land>United States</land>
            <county>Hampden</county>
            <grid>FN32aa</grid>
            <lat>42.101234</lat>
            <lon>-72.589012</lon>
            <dxcc>291</dxcc>
            <ccode>271</ccode>
            <cqzone>5</cqzone>
            <ituzone>8</ituzone>
            <class>E</class>
            <email>nobody@example.invalid</email>
          </Callsign>
          <Session>
            <Key>\(key)</Key>
            <Count>128</Count>
            <SubExp>Tue Dec 31 23:59:59 2026</SubExp>
          </Session>
        </QRZDatabase>
        """
    }

    /// A thin record: QRZ has the callsign but little else, which is normal for club
    /// stations and special event calls.
    static func sparseCallsign(_ call: String = "K2XYZ") -> String {
        """
        <?xml version="1.0" encoding="utf-8" ?>
        <QRZDatabase version="1.34" xmlns="http://xmldata.qrz.com">
          <Callsign>
            <call>\(call)</call>
            <fname></fname>
            <name>Springfield Radio Club</name>
            <addr2>   </addr2>
            <dxcc>291</dxcc>
          </Callsign>
          <Session>
            <Key>3bd4a1e6f8c0d2b5a7e9f1c3d5b7a9e1</Key>
          </Session>
        </QRZDatabase>
        """
    }
}
