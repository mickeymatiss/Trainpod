import Foundation

/// Existing production text format; it is not wrapped in the test firmware's protocol.
struct TransitMessage {
    static let unavailablePayload = Data("TP2\n!\n".utf8)
    static let dummyPayload = String(decoding: completePayload("TP2\nMorgan\nP\tWest\nA\tGreen\t009B3A\tHarlem/Lake\t2\nA\tPink\tE27EA6\t54th/Cermak\t6\nA\tGreen\t009B3A\tAshland\t10\nA\tPink\tE27EA6\t54th/Cermak\t13\nP\tEast\nA\tGreen\t009B3A\tCottage Grove\t3\nA\tPink\tE27EA6\tLoop\t8\n"), as: UTF8.self)
    // Application-level completeness check; BLE fragmentation is unchanged.
    static func completePayload(_ body: String) -> Data {
        let bytes = Data(body.utf8)
        let checksum = bytes.reduce(UInt32(2166136261)) { ($0 ^ UInt32($1)) &* 16777619 }
        return bytes + Data("END\t\(bytes.count)\t\(String(format: "%08X", checksum))\n".utf8)
    }
    static func encode(_ payload: String) -> Data { Data(payload.utf8) }
    static func encode(stationName: String, direction1Name: String, direction1ETAs: [Int],
                       direction2Name: String, direction2ETAs: [Int]) -> Data {
        encode([stationName, direction1Name, direction1ETAs.prefix(3).map(String.init).joined(separator: ","),
                direction2Name, direction2ETAs.prefix(3).map(String.init).joined(separator: ",")].joined(separator: "|"))
    }
}
