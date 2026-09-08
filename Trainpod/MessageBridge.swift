import Combine
import Foundation

typealias BLEWriteMode = BluetoothService.BLEWriteMode

/// Owns logical framing and ACK bookkeeping. No CoreBluetooth or workload knowledge.
@MainActor
final class MessageBridge: ObservableObject {
    enum WireFormat { case slip, plainText }
    enum BridgeError: LocalizedError {
        case notReady, invalidMessage, busy, duplicateSequence, cancelled
        var errorDescription: String? {
            switch self {
            case .notReady: return "Connection or notification subscription is not ready."
            case .invalidMessage: return "Invalid logical message or payload exceeds 32768 bytes."
            case .busy: return "Another logical message is being submitted."
            case .duplicateSequence: return "Sequence is already pending or acknowledged in this session."
            case .cancelled: return "Message session was cancelled."
            }
        }
    }
    struct Acknowledgement {
        enum Status: UInt8 {
            case ok = 0, checksumError = 1, malformed = 2, sizeError = 3
            var name: String {
                switch self {
                case .ok: return "OK"
                case .checksumError: return "CHECKSUM_ERROR"
                case .malformed: return "MALFORMED"
                case .sizeError: return "SIZE_ERROR"
                }
            }
        }
        let sequence: UInt32
        let size: Int
        let status: Status
        init?(data: Data) {
            let bytes = [UInt8](data)
            guard bytes.count == 10, bytes[0] == 1, let status = Status(rawValue: bytes[1]) else { return nil }
            sequence = MessageBridge.uint32(bytes, at: 2)
            size = Int(MessageBridge.uint32(bytes, at: 6))
            self.status = status
        }
    }
    enum Event {
        case acknowledged(Acknowledgement, expectedSize: Int, roundTrip: TimeInterval)
        case duplicate(UInt32), unexpected(UInt32), malformed(Data)
        case timedOut([UInt32]), drained
    }
    var messageReceivedHandler: ((Data) -> Void)?
    var eventHandler: ((Event) -> Void)?
    @Published private(set) var lastSentMessage: Data?
    @Published private(set) var lastError: String?

    private let bluetooth: BluetoothService
    private let wireFormat: WireFormat
    private struct Pending { let size: Int; let started: Date }
    private var pending: [UInt32: Pending] = [:]
    private var acknowledged: Set<UInt32> = []
    private var submissionsFinished = false
    private var timeoutTask: Task<Void, Never>?
    private var receiveTimeoutTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var sending = false
    private var receiveBuffer = Data()
    private var receivingFrame = false
    private var escaped = false
    private var invalidFrame = false
    private static let maximumPayload = 32768

    init(bluetooth: BluetoothService, wireFormat: WireFormat = .slip) {
        self.bluetooth = bluetooth
        self.wireFormat = wireFormat
        bluetooth.receivedDataHandler = { [weak self] data in self?.receive(data) }
        bluetooth.connectionStateHandler = { [weak self] state in
            if state != .connected { self?.clearReceiveState() }
        }
    }

    deinit { timeoutTask?.cancel(); receiveTimeoutTask?.cancel() }

    var canSend: Bool {
        bluetooth.canSend && (wireFormat == .plainText || bluetooth.notificationsReady)
    }
    var pendingCount: Int { pending.count }
    var isSending: Bool { sending }

    /// Returns after all chunks have been submitted, preserving the existing burst behavior.
    /// ACK outcomes arrive through eventHandler. No application retries are performed.
    func send(_ message: Data, mode: BLEWriteMode = .withResponse) async throws {
        try Task.checkCancellation()
        guard canSend else { throw BridgeError.notReady }
        guard !sending else { throw BridgeError.busy }
        let chunkSize = bluetooth.maximumWriteValueLength(for: mode)
        guard chunkSize > 0 else { throw BridgeError.notReady }
        let session = generation
        let sequence: UInt32?
        let bytes: Data
        if wireFormat == .slip {
            guard Self.isValidLogicalMessage(message) else { throw BridgeError.invalidMessage }
            let header = [UInt8](message.prefix(10))
            let id = Self.uint32(header, at: 2)
            guard pending[id] == nil, !acknowledged.contains(id) else { throw BridgeError.duplicateSequence }
            sequence = id
            pending[id] = Pending(size: Int(Self.uint32(header, at: 6)), started: Date())
            bytes = Self.frame(message)
        } else {
            // The production demo consumes one plain UTF-8 value and has no ACK protocol.
            sequence = nil
            bytes = message
            FileLogger.shared.log("[BLE] Display response send started bytes=\(message.count)")
        }
        sending = true
        defer { sending = false }
        do {
            for offset in stride(from: 0, to: bytes.count, by: chunkSize) {
                try Task.checkCancellation()
                guard session == generation else { throw BridgeError.cancelled }
                let end = min(offset + chunkSize, bytes.count)
                try await bluetooth.write(bytes.subdata(in: offset..<end), mode: mode)
            }
            guard session == generation else { throw BridgeError.cancelled }
            if wireFormat == .plainText {
                // Receiver uses a 250ms idle boundary. Keep the send coalesced through
                // that boundary so a retry cannot concatenate two complete boards.
                try await Task.sleep(for: .milliseconds(300))
            }
            lastSentMessage = message
            lastError = nil
            if wireFormat == .plainText { FileLogger.shared.log("[BLE] Display response sent bytes=\(message.count)") }
        } catch {
            if wireFormat == .plainText { FileLogger.shared.log("[BLE] Display response failed code=\((error as NSError).code)") }
            if session == generation {
                if let sequence { pending[sequence] = nil }
                lastError = error.localizedDescription
            }
            throw error
        }
    }

    /// The existing harness allows two seconds for outstanding ACKs after the last submission.
    func finishSubmissions() {
        submissionsFinished = true
        timeoutTask?.cancel()
        if pending.isEmpty { eventHandler?(.drained); return }
        let session = generation
        timeoutTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
            guard let self, self.generation == session else { return }
            let missing = Array(self.pending.keys).sorted()
            self.pending.removeAll()
            self.eventHandler?(.timedOut(missing))
        }
    }

    func reset() {
        generation &+= 1
        timeoutTask?.cancel(); timeoutTask = nil
        pending.removeAll(); acknowledged.removeAll()
        submissionsFinished = false
        lastError = nil
        clearReceiveState()
    }

    /// The unchanged version/type/sequence/length/payload/CRC layout, before SLIP encoding.
    static func makeMessage(type: UInt8, sequence: UInt32, payload: Data) -> Data {
        var message = Data([1, type])
        appendUInt32(sequence, to: &message)
        appendUInt32(UInt32(payload.count), to: &message)
        message.append(payload)
        appendUInt32(checksum(payload), to: &message)
        return message
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ ((crc & 1) == 1 ? 0xEDB8_8320 : 0) }
        }
        return crc ^ 0xFFFF_FFFF
    }

    static func frame(_ message: Data) -> Data {
        var framed = Data([0xC0])
        for byte in message {
            switch byte {
            case 0xC0: framed.append(contentsOf: [0xDB, 0xDC])
            case 0xDB: framed.append(contentsOf: [0xDB, 0xDD])
            default: framed.append(byte)
            }
        }
        framed.append(0xC0)
        return framed
    }

    private static func isValidLogicalMessage(_ data: Data) -> Bool {
        let bytes = [UInt8](data)
        guard bytes.count >= 14, bytes[0] == 1, bytes[1] == 1 || bytes[1] == 2 else { return false }
        let size = Int(uint32(bytes, at: 6))
        guard size <= maximumPayload, bytes.count == size + 14,
              bytes[1] != 2 || size == 0 else { return false }
        return checksum(Data(bytes[10..<(10 + size)])) == uint32(bytes, at: 10 + size)
    }

    private static func appendUInt32(_ value: UInt32, to data: inout Data) {
        for shift in stride(from: 0, to: 32, by: 8) { data.append(UInt8(truncatingIfNeeded: value >> shift)) }
    }

    nonisolated private static func uint32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 |
        UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
    }

    private func receive(_ data: Data) {
        if wireFormat == .plainText {
            messageReceivedHandler?(data)
            return
        }
        // ACKs are raw, atomic 10-byte notifications in the existing protocol.
        // They fit the minimum ATT payload; do not concatenate malformed ACK packets.
        if let ack = Acknowledgement(data: data) {
            messageReceivedHandler?(data)
            if acknowledged.contains(ack.sequence) { eventHandler?(.duplicate(ack.sequence)); return }
            guard let sent = pending.removeValue(forKey: ack.sequence) else {
                eventHandler?(.unexpected(ack.sequence)); return
            }
            acknowledged.insert(ack.sequence)
            eventHandler?(.acknowledged(ack, expectedSize: sent.size, roundTrip: Date().timeIntervalSince(sent.started)))
            if submissionsFinished && pending.isEmpty {
                timeoutTask?.cancel(); timeoutTask = nil
                eventHandler?(.drained)
            }
            return
        }
        guard receivingFrame || data.first == 0xC0 else { eventHandler?(.malformed(data)); return }
        for byte in data {
            if byte == 0xC0 {
                if !receiveBuffer.isEmpty || escaped || invalidFrame {
                    if !escaped && !invalidFrame && Self.isValidLogicalMessage(receiveBuffer) {
                        messageReceivedHandler?(receiveBuffer)
                    } else { eventHandler?(.malformed(receiveBuffer)) }
                }
                receiveBuffer.removeAll(keepingCapacity: true)
                escaped = false; invalidFrame = false; receivingFrame = true
            } else if escaped {
                escaped = false
                if byte == 0xDC { appendReceived(0xC0) }
                else if byte == 0xDD { appendReceived(0xDB) }
                else { invalidFrame = true }
            } else if byte == 0xDB { escaped = true }
            else { appendReceived(byte) }
        }
        receiveTimeoutTask?.cancel()
        if !receiveBuffer.isEmpty || escaped || invalidFrame {
            receiveTimeoutTask = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: 3_000_000_000) } catch { return }
                guard let self else { return }
                let incomplete = self.receiveBuffer
                self.clearReceiveState()
                self.eventHandler?(.malformed(incomplete))
            }
        }
    }

    private func appendReceived(_ byte: UInt8) {
        if receiveBuffer.count < Self.maximumPayload + 14 { receiveBuffer.append(byte) }
        else { invalidFrame = true }
    }

    private func clearReceiveState() {
        receiveTimeoutTask?.cancel(); receiveTimeoutTask = nil
        receiveBuffer.removeAll(keepingCapacity: true)
        receivingFrame = false; escaped = false; invalidFrame = false
    }
}
