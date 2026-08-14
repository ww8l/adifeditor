import Testing
import Foundation
@testable import QRZKit

/// Reading QRZ's XML, and turning one record into ADIF values.
///
/// The stakes here are lower than the parser's — a misread response fills a cell wrong,
/// it does not corrupt a log — but a wrong `CNTY` or a wrong `DXCC` uploaded to POTA is
/// still a wrong log, and the operator has no way to tell it came from a bad mapping.
@Suite("QRZ responses")
struct QRZParsingTests {

    // MARK: - Document shape

    @Test("a sign-in response yields the session key")
    func readsSessionKey() throws {
        let response = try QRZResponseParser.parse(Data(QRZFixtures.session(key: "abc123").utf8))

        #expect(response.sessionKey == "abc123")
        #expect(response.error == nil)
        #expect(response.callsign == nil)
    }

    @Test("an error element is reported as an error, not as a missing key")
    func readsSessionError() throws {
        let response = try QRZResponseParser.parse(
            Data(QRZFixtures.sessionError("Username/password incorrect").utf8))

        #expect(response.error == "Username/password incorrect")
        #expect(response.sessionKey == nil)
    }

    @Test("a callsign record yields its elements and refreshes the key")
    func readsCallsign() throws {
        let response = try QRZResponseParser.parse(Data(QRZFixtures.callsign().utf8))
        let record = try #require(response.callsign)

        #expect(record.call == "W1ABC")
        #expect(record["grid"] == "FN32aa")
        #expect(record["cqzone"] == "5")
        #expect(response.sessionKey == "3bd4a1e6f8c0d2b5a7e9f1c3d5b7a9e1")
    }

    @Test("elements QRZKit has no opinion about are kept anyway")
    func keepsUnknownElements() throws {
        // The same reasoning as §6.2 in the ADIF parser: QRZ adds elements without
        // notice, and a fixed set of properties would drop them silently.
        let response = try QRZResponseParser.parse(Data(QRZFixtures.callsign().utf8))
        let record = try #require(response.callsign)

        #expect(record["class"] == "E")
        #expect(record["ccode"] == "271")
    }

    @Test("a value split by an entity reference is reassembled whole")
    func reassemblesSplitText() throws {
        // XMLParser delivers "Smith & Sons" as three separate foundCharacters calls.
        // Keeping only the last would store " Sons".
        let response = try QRZResponseParser.parse(Data("""
            <QRZDatabase><Callsign><name>Smith &amp; Sons</name></Callsign></QRZDatabase>
            """.utf8))

        #expect(response.callsign?["name"] == "Smith & Sons")
    }

    @Test("a present-but-blank element reads as absent")
    func blankElementsAreAbsent() throws {
        let response = try QRZResponseParser.parse(Data(QRZFixtures.sparseCallsign().utf8))
        let record = try #require(response.callsign)

        // QRZ sends <fname></fname> and <addr2>   </addr2> for data it lacks. Writing
        // those into a log would be filling a cell with nothing.
        #expect(record["fname"] == nil)
        #expect(record["addr2"] == nil)
        #expect(record["dxcc"] == "291")
    }

    @Test("session elements are matched whatever their case")
    func sessionCaseInsensitive() throws {
        // QRZ writes <Key> in the session block and <call> in the callsign block. Relying
        // on either spelling breaks the day they tidy their serializer.
        let response = try QRZResponseParser.parse(Data("""
            <QRZDatabase><SESSION><KEY>k</KEY></SESSION></QRZDatabase>
            """.utf8))

        #expect(response.sessionKey == "k")
    }

    // MARK: - Malformed input (§6.4)

    @Test("an empty body is refused, not read as an empty success")
    func emptyBody() {
        #expect(throws: QRZError.malformedResponse("the response was empty")) {
            try QRZResponseParser.parse(Data())
        }
    }

    @Test("a truncated body is refused")
    func truncatedBody() {
        let truncated = String(QRZFixtures.callsign().prefix(180))

        #expect(throws: QRZError.self) {
            try QRZResponseParser.parse(Data(truncated.utf8))
        }
    }

    @Test("an HTML error page from a proxy is refused")
    func htmlErrorPage() {
        // A captive portal or a corporate proxy answers with this, not with XML.
        #expect(throws: QRZError.self) {
            try QRZResponseParser.parse(Data("<html><body>403 Forbidden</body></html>".utf8))
        }
    }

    @Test("well-formed XML from somewhere else is refused")
    func wrongXML() {
        // Well-formed, so XMLParser is happy; it is simply not QRZ. Without the
        // QRZDatabase check this would parse to an empty success and the operator would
        // be told every callsign came back blank.
        #expect(throws: QRZError.malformedResponse("the response was XML, but not from QRZ")) {
            try QRZResponseParser.parse(Data("<rss><channel><title>x</title></channel></rss>".utf8))
        }
    }

    // MARK: - Field mapping

    @Test("the formatted name wins over first and last")
    func prefersFormattedName() throws {
        let record = try #require(
            try QRZResponseParser.parse(Data(QRZFixtures.callsign().utf8)).callsign)

        #expect(record.fullName == "John Q Public")
    }

    @Test("without a formatted name, first and last are joined")
    func joinsNames() {
        let record = QRZCallsign(elements: ["fname": "Jane", "name": "Doe"])
        #expect(record.fullName == "Jane Doe")
    }

    @Test("one name is better than none")
    func partialName() {
        #expect(QRZCallsign(elements: ["name": "Springfield Radio Club"]).fullName
                == "Springfield Radio Club")
        #expect(QRZCallsign(elements: ["fname": "Jane"]).fullName == "Jane")
        #expect(QRZCallsign(elements: [:]).fullName == nil)
    }

    @Test("county is qualified by state, as ADIF requires")
    func qualifiesCounty() {
        // ADIF's CNTY is "MA,Hampden", not "Hampden". Writing the bare county produces a
        // field that looks filled and is not valid.
        let record = QRZCallsign(elements: ["county": "Hampden", "state": "MA"])
        #expect(record.county == "MA,Hampden")
    }

    @Test("a county with no state is dropped rather than written half-formed")
    func countyNeedsState() {
        #expect(QRZCallsign(elements: ["county": "Hampden"]).county == nil)
    }

    @Test("COUNTRY takes the DXCC entity, not the mailing address")
    func prefersDXCCEntity() {
        // A US callsign held by someone living in Germany: the QSO's DXCC entity is the
        // United States, and that is what a log's COUNTRY means.
        let record = QRZCallsign(elements: ["land": "United States", "country": "Germany"])
        #expect(record.country == "United States")

        #expect(QRZCallsign(elements: ["country": "Germany"]).country == "Germany",
                "and falls back rather than writing nothing")
    }

    @Test("the street address is never offered")
    func neverOffersStreetAddress() throws {
        // Home addresses do not belong in a log the operator uploads. addr1 is in the
        // record and must not reach the mapping.
        let record = try #require(
            try QRZResponseParser.parse(Data(QRZFixtures.callsign().utf8)).callsign)
        let values = QRZFieldMapping.values(from: record)

        #expect(!values.contains { $0.value.contains("123 Main Street") })
        #expect(record["addr1"] == "123 Main Street", "though it was parsed")
    }

    @Test("a full record maps to the documented ADIF fields")
    func mapsFullRecord() throws {
        let record = try #require(
            try QRZResponseParser.parse(Data(QRZFixtures.callsign().utf8)).callsign)

        let mapped = Dictionary(uniqueKeysWithValues:
            QRZFieldMapping.values(from: record).map { ($0.field, $0.value) })

        #expect(mapped == [
            "NAME": "John Q Public",
            "QTH": "Springfield",
            "STATE": "MA",
            "CNTY": "MA,Hampden",
            "GRIDSQUARE": "FN32aa",
            "COUNTRY": "United States",
            "DXCC": "291",
            "CQZ": "5",
            "ITUZ": "8"
        ])
    }

    @Test("a sparse record maps only what it has")
    func mapsSparseRecord() throws {
        let record = try #require(
            try QRZResponseParser.parse(Data(QRZFixtures.sparseCallsign().utf8)).callsign)

        #expect(QRZFieldMapping.values(from: record).map(\.field) == ["NAME", "DXCC"])
    }
}
