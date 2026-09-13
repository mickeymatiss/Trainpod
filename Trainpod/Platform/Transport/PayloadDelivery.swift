import Foundation

nonisolated struct PayloadTransaction: Hashable, Sendable {
    let boot: UInt32
    let request: UInt32
    var id: String { "\(boot)-\(request)" }
}
nonisolated enum PayloadDelivery {
    static func transaction(_ bytes: [UInt8]) -> PayloadTransaction {
        PayloadTransaction(boot: u32(bytes, 3), request: u32(bytes, 7))
    }
    static func u32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | UInt32(bytes[offset+1])<<8 | UInt32(bytes[offset+2])<<16 | UInt32(bytes[offset+3])<<24
    }
    static func request(_ data: Data) -> PayloadTransaction? {
        let b = [UInt8](data)
        guard b.count == 11, b[0] == 80, b[1] == 49, b[2] == 1 else { return nil }
        let tx = transaction(b)
        return tx.request != 0 ? tx : nil
    }
    static func acknowledgement(_ data: Data) -> (PayloadTransaction, UInt8, Int)? {
        let b = [UInt8](data)
        guard b.count == 14, b[0] == 80, b[1] == 49, b[2] == 3 else { return nil }
        return (transaction(b), b[11], Int(b[12]) | Int(b[13])<<8)
    }
    static func header(_ tx: PayloadTransaction, payload: Data, chunks: Int) -> Data {
        var bytes: [UInt8] = [80, 49, 2]
        for value in [tx.boot, tx.request] {
            for shift in stride(from: 0, to: 32, by: 8) { bytes.append(UInt8(truncatingIfNeeded: value >> shift)) }
        }
        for value in [payload.count, chunks] { bytes += [UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8)] }
        var crc: UInt32 = 0xffffffff
        for byte in payload { crc ^= UInt32(byte); for _ in 0..<8 { crc = (crc>>1) ^ ((crc&1) != 0 ? 0xedb88320 : 0) } }
        crc ^= 0xffffffff
        for shift in stride(from: 0, to: 32, by: 8) { bytes.append(UInt8(truncatingIfNeeded: crc >> shift)) }
        return Data(bytes)
    }
}

nonisolated enum PhoneDiagnosticContext {
    @TaskLocal static var transactionId: String?
}
