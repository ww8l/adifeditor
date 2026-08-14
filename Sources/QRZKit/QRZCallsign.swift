import Foundation

/// One station's details, as QRZ returned them.
///
/// Stored as the raw elements rather than a fixed set of properties. QRZ adds elements
/// to this record without announcement, and a struct with named fields would silently
/// drop anything new — the same failure mode §6.2 forbids in the parser, for the same
/// reason. The typed accessors below are a convenience over the dictionary, not a
/// replacement for it.
public struct QRZCallsign: Equatable, Sendable {

    /// Element name (lowercased, as QRZ's own are) to text content.
    public let elements: [String: String]

    public init(elements: [String: String]) {
        self.elements = elements
    }

    /// Trimmed, and `nil` rather than empty — QRZ returns present-but-blank elements for
    /// data it does not have, and an empty string would otherwise look like a value
    /// worth writing into the log.
    public subscript(element: String) -> String? {
        guard let raw = elements[element.lowercased()] else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    // MARK: - The fields the log cares about

    public var call: String? { self["call"] }

    /// QRZ's `name_fmt` is the full name already assembled the way the operator asked it
    /// to be shown, so it wins when present. Otherwise first and last are joined —
    /// `fname` alone or `name` alone is still better than nothing.
    public var fullName: String? {
        if let formatted = self["name_fmt"] { return formatted }
        let parts = [self["fname"], self["name"]].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// The city. QRZ's `addr2` is the city line of the mailing address; `addr1` is the
    /// street, which does not belong in a log.
    public var city: String? { self["addr2"] }

    public var state: String? { self["state"] }

    /// QRZ gives a bare county name (`Hampden`). ADIF's `CNTY` wants it qualified by the
    /// primary administrative subdivision (`MA,Hampden`), so without a state there is
    /// nothing valid to write and this returns `nil` rather than a half-formed value.
    public var county: String? {
        guard let county = self["county"], let state = state else { return nil }
        return "\(state),\(county)"
    }

    public var gridSquare: String? { self["grid"] }

    /// `land` is the DXCC entity, which is what ADIF's `COUNTRY` means. `country` is the
    /// mailing address's country and can differ — a US callsign held by someone living
    /// abroad. Prefer the entity, fall back rather than write nothing.
    public var country: String? { self["land"] ?? self["country"] }

    public var dxcc: String? { self["dxcc"] }
    public var cqZone: String? { self["cqzone"] }
    public var ituZone: String? { self["ituzone"] }
}
