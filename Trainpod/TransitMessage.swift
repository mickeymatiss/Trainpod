import Foundation

/// Existing production text format; it is not wrapped in the test firmware's protocol.
struct TransitMessage {
    static let dummyPayload = "Morgan|54th/Cermak or Harlem/Lake|Pink:E27EA6:1,3;Green:009B3A:5|Loop or 63rd St|Green:009B3A:5,11;Pink:E27EA6:8"
    static func encode(_ payload: String) -> Data { Data(payload.utf8) }
    static func encode(stationName: String, direction1Name: String, direction1ETAs: [Int],
                       direction2Name: String, direction2ETAs: [Int]) -> Data {
        encode([stationName, direction1Name, direction1ETAs.prefix(3).map(String.init).joined(separator: ","),
                direction2Name, direction2ETAs.prefix(3).map(String.init).joined(separator: ",")].joined(separator: "|"))
    }
}
