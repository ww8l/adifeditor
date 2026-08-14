import Foundation

/// Which ADIF fields a QRZ record can supply, and where each one comes from.
///
/// The list is short on purpose. QRZ returns a great deal more — street address, email,
/// licence class, QSL routes, latitude and longitude — and almost none of it belongs in
/// a log. Two exclusions are worth naming because they look like omissions:
///
///   - **`LAT` / `LON`.** QRZ gives signed decimal degrees; ADIF wants `XDDD MM.MMM`
///     with a hemisphere letter. Converting is easy to do and easy to do subtly wrong,
///     and `GRIDSQUARE` already carries the position at the precision a log needs.
///   - **`ADDRESS`.** A home street address is not log data, and writing one into a file
///     the operator then uploads to POTA would be handing out something they did not
///     mean to publish.
public enum QRZFieldMapping {

    /// An ADIF field and how to get it out of a QRZ record.
    public struct Mapping: Sendable {
        public let field: String
        public let value: @Sendable (QRZCallsign) -> String?
    }

    /// Order matters only for how proposals are listed to the operator; it runs from the
    /// fields they are most likely to want to the ones they are least likely to notice.
    public static let mappings: [Mapping] = [
        Mapping(field: "NAME") { $0.fullName },
        Mapping(field: "QTH") { $0.city },
        Mapping(field: "STATE") { $0.state },
        Mapping(field: "CNTY") { $0.county },
        Mapping(field: "GRIDSQUARE") { $0.gridSquare },
        Mapping(field: "COUNTRY") { $0.country },
        Mapping(field: "DXCC") { $0.dxcc },
        Mapping(field: "CQZ") { $0.cqZone },
        Mapping(field: "ITUZ") { $0.ituZone }
    ]

    /// The ADIF field names this can fill, in the order above.
    public static var fields: [String] { mappings.map(\.field) }

    /// Everything this record has to offer, skipping what QRZ did not return.
    public static func values(from callsign: QRZCallsign) -> [(field: String, value: String)] {
        mappings.compactMap { mapping in
            guard let value = mapping.value(callsign) else { return nil }
            return (field: mapping.field, value: value)
        }
    }
}
