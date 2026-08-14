import Foundation

/// What came back from one request.
///
/// QRZ answers authentication and lookup with the same document shape, so one parser
/// serves both: a `<Session>` block is always present, and a `<Callsign>` block appears
/// when the lookup succeeded. Errors arrive inside `<Session><Error>` as human text
/// rather than as a code, which is why classifying them is a separate step (`QRZSession`)
/// from reading them.
public struct QRZResponse: Equatable, Sendable {
    public let callsign: QRZCallsign?
    public let sessionKey: String?
    public let error: String?
    public let message: String?
}

/// Reads QRZ's XML.
///
/// `XMLParser` rather than anything hand-rolled: it is in Foundation, it rejects
/// malformed documents rather than guessing, and §5's "no dependencies, ever" rules out
/// the alternatives anyway.
public enum QRZResponseParser {

    public static func parse(_ data: Data) throws -> QRZResponse {
        guard !data.isEmpty else {
            throw QRZError.malformedResponse("the response was empty")
        }

        let parser = XMLParser(data: data)
        let collector = Collector()
        parser.delegate = collector

        guard parser.parse() else {
            // A proxy's HTML error page, a captive portal, or a body cut off mid-transfer
            // all land here. Quote the parser rather than inventing a diagnosis.
            let reason = parser.parserError?.localizedDescription ?? "unrecognised content"
            throw QRZError.malformedResponse(reason)
        }

        guard collector.sawDatabaseElement else {
            throw QRZError.malformedResponse("the response was XML, but not from QRZ")
        }

        return QRZResponse(
            callsign: collector.callsignElements.isEmpty
                ? nil
                : QRZCallsign(elements: collector.callsignElements),
            sessionKey: collector.trimmedSession["key"],
            error: collector.trimmedSession["error"],
            message: collector.trimmedSession["message"]
        )
    }

    /// Accumulates elements by which block they sit in.
    ///
    /// Element names are lowercased on the way in. QRZ writes `<Session><Key>` in title
    /// case and `<Callsign><call>` in lower, and depending on that is asking for a break
    /// the first time they tidy their serializer.
    private final class Collector: NSObject, XMLParserDelegate {

        private enum Block { case callsign, session }

        var callsignElements: [String: String] = [:]
        var sessionElements: [String: String] = [:]
        var sawDatabaseElement = false

        private var block: Block?
        private var currentElement: String?
        private var text = ""

        /// Session values trimmed and emptied-to-absent, matching `QRZCallsign`'s
        /// subscript: an `<Error></Error>` element is not an error.
        var trimmedSession: [String: String] {
            sessionElements.compactMapValues { value in
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
        }

        func parser(_ parser: XMLParser,
                    didStartElement elementName: String,
                    namespaceURI: String?,
                    qualifiedName: String?,
                    attributes: [String: String]) {
            let name = elementName.lowercased()

            switch name {
            case "qrzdatabase":
                sawDatabaseElement = true
            case "callsign":
                block = .callsign
            case "session":
                block = .session
            default:
                currentElement = name
                text = ""
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard currentElement != nil else { return }
            text += string
        }

        func parser(_ parser: XMLParser,
                    didEndElement elementName: String,
                    namespaceURI: String?,
                    qualifiedName: String?) {
            let name = elementName.lowercased()

            if name == "callsign" || name == "session" {
                block = nil
                currentElement = nil
                return
            }

            guard let currentElement, currentElement == name else { return }

            // `text` is the whole element: `foundCharacters` arrives in several calls
            // whenever an entity reference (`&amp;`) splits the run, and they have been
            // accumulating since `didStartElement` cleared it.
            switch block {
            case .callsign: callsignElements[name] = text
            case .session: sessionElements[name] = text
            case nil: break
            }

            self.currentElement = nil
            text = ""
        }
    }
}
