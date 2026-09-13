import Foundation

/// Diagnostics-only envelope. No dependency on transit framing or payloads.
struct DiagnosticPacket {
    let kind: UInt8
    let exportID: UInt32
    let body: Data
    static func isDiagnostic(_ data: Data) -> Bool { data.starts(with: [0xd1, 0xa6]) }
    init(_ data: Data) throws {
        let bytes = [UInt8](data)
        guard bytes.count >= 8, Self.isDiagnostic(data), bytes[2] == 1 else { throw DiagnosticError.invalidPacket }
        kind = bytes[3]; exportID = Self.u32(bytes, 4); body = Data(bytes.dropFirst(8))
        guard exportID != 0 else { throw DiagnosticError.invalidPacket }
    }
    static func u32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | UInt32(bytes[offset+1]) << 8 | UInt32(bytes[offset+2]) << 16 | UInt32(bytes[offset+3]) << 24
    }
    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffffffff
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ ((crc & 1) == 1 ? 0xedb88320 : 0) }
        }
        return crc ^ 0xffffffff
    }
}
enum DiagnosticError: LocalizedError {
    case invalidPacket, invalidOrder, checksum, timeout, disconnected, unavailable, save(String)
    case stageTimeout(String), deviceFailure(UInt8)
    var errorDescription: String? {
        switch self {
        case .invalidPacket: return "The device sent an invalid diagnostics packet. Logs were not cleared."
        case .invalidOrder: return "Diagnostics were incomplete or out of order. Logs were not cleared."
        case .checksum: return "Diagnostics failed the integrity check. Logs were not cleared."
        case .stageTimeout(let stage): return "Diagnostics timed out: \(stage). No receipt ACK was sent."
        case .deviceFailure(let code):
            let reason: String
            switch code {
            case 1: reason = "export cancelled or connection lost"
            case 2: reason = "could not allocate/build the export snapshot or it exceeded the 65,000-byte limit"
            case 3: reason = "device transfer deadline expired"
            case 4: reason = "negotiated notification MTU is too small"
            case 5: reason = "could not persist the diagnostic counters to device storage"
            default: reason = "unknown export failure code \(code)"
            }
            return "Device diagnostics failed: \(reason). Device logs were not cleared."
        case .timeout: return "Diagnostics timed out. Wake the device and try again."
        case .disconnected: return "The device disconnected. Unacknowledged logs remain on the device."
        case .unavailable: return "Diagnostics are unavailable during the BLE reconnect experiment."
        case .save(let detail): return "Could not save diagnostics: \(detail). Device logs were not cleared."
        }
    }
}

struct DiagnosticAssembler {
    private(set) var exportID: UInt32?
    private(set) var total = 0
    private(set) var data = Data()
    private var crc: UInt32 = 0
    private(set) var complete = false

    mutating func accept(_ packet: DiagnosticPacket) throws -> Data? {
        let bytes = [UInt8](packet.body)
        if packet.kind == 1 {
            guard exportID == nil, bytes.count == 10, bytes[0] == 1, bytes[1] == 0 else { throw DiagnosticError.invalidPacket }
            total = Int(DiagnosticPacket.u32(bytes,2))
            guard total > 0 && total <= 96000 else { throw DiagnosticError.invalidPacket }
            crc = DiagnosticPacket.u32(bytes,6); exportID = packet.exportID
            data.reserveCapacity(total)
        } else {
            guard packet.exportID == exportID, !complete else { throw DiagnosticError.invalidOrder }
            if packet.kind == 2 {
                guard bytes.count > 4, Int(DiagnosticPacket.u32(bytes,0)) == data.count,
                      data.count + bytes.count - 4 <= total else { throw DiagnosticError.invalidOrder }
                data.append(contentsOf: bytes.dropFirst(4))
            } else if packet.kind == 3 {
                guard bytes.count == 4, data.count == total else { throw DiagnosticError.invalidOrder }
                guard DiagnosticPacket.u32(bytes,0) == crc, DiagnosticPacket.checksum(data) == crc,
                      String(data: data, encoding: .utf8) != nil else { throw DiagnosticError.checksum }
                complete = true
                return data
            } else { throw DiagnosticError.invalidPacket }
        }
        return nil
    }
}
