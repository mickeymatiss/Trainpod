import Combine
import Foundation

@MainActor
final class BLETestRunner: ObservableObject {
    enum SendInterval: String, CaseIterable, Identifiable {
        case maximumSpeed = "Maximum"
        case oneMillisecond = "1 ms"
        case fiveMilliseconds = "5 ms"
        case tenMilliseconds = "10 ms"
        case twentyFiveMilliseconds = "25 ms"
        case fiftyMilliseconds = "50 ms"
        case oneHundredMilliseconds = "100 ms"
        case custom = "Custom"

        var id: String { rawValue }

        func nanoseconds(customMilliseconds: Int) -> UInt64? {
            let milliseconds: Int?
            switch self {
            case .maximumSpeed:
                milliseconds = nil
            case .oneMillisecond:
                milliseconds = 1
            case .fiveMilliseconds:
                milliseconds = 5
            case .tenMilliseconds:
                milliseconds = 10
            case .twentyFiveMilliseconds:
                milliseconds = 25
            case .fiftyMilliseconds:
                milliseconds = 50
            case .oneHundredMilliseconds:
                milliseconds = 100
            case .custom:
                milliseconds = max(0, customMilliseconds)
            }

            guard let milliseconds else {
                return nil
            }
            return UInt64(milliseconds) * 1_000_000
        }
    }

    struct Statistics {
        var messagesAttempted = 0
        var messagesSent = 0
        var acknowledgementsReceived = 0
        var messagesFailed = 0
        var messagesMissing = 0
        var duplicateAcknowledgements = 0
        var unexpectedAcknowledgements = 0
        var corruptMessages = 0
        var bytesSent = 0
        var bytesAcknowledged = 0
        var elapsedTime: TimeInterval = 0
        var currentRTT: TimeInterval?
        var averageRTT: TimeInterval?
        var minimumRTT: TimeInterval?
        var maximumRTT: TimeInterval?

        var messagesPerSecond: Double {
            guard elapsedTime > 0 else {
                return 0
            }
            return Double(acknowledgementsReceived) / elapsedTime
        }

        var kilobytesPerSecond: Double {
            guard elapsedTime > 0 else {
                return 0
            }
            return Double(bytesAcknowledged) / 1000 / elapsedTime
        }

        var errorRate: Double {
            guard messagesSent > 0 else {
                return 0
            }
            let errors = messagesFailed + messagesMissing + duplicateAcknowledgements + unexpectedAcknowledgements + corruptMessages
            return Double(errors) / Double(messagesSent)
        }
    }

    @Published var payloadSize = 512
    @Published var messageCount = 100
    @Published var customIntervalMilliseconds = 10
    @Published var sendInterval: SendInterval = .maximumSpeed
    @Published var writeMode: BLEWriteMode = .withResponse
    @Published private(set) var isRunning = false
    @Published private(set) var statistics = Statistics()
    @Published private(set) var summary = "No test run yet."
    @Published private(set) var recentEvents: [String] = []

    private let bridge: MessageBridge
    private var runTask: Task<Void, Never>?
    private var startedAt: Date?
    private var nextSequence: UInt32 = 1
    private var rttSamples: [TimeInterval] = []
    private var runID: UInt64 = 0

    init(bridge: MessageBridge) {
        self.bridge = bridge
        bridge.eventHandler = { [weak self] event in self?.handle(event) }
    }

    deinit { runTask?.cancel() }

    func startTest() {
        guard !isRunning else { return }
        guard bridge.canSend else {
            summary = "Wait for the BLE connection and ACK notification subscription."
            return
        }
        guard (0...32768).contains(payloadSize) else {
            summary = "Payload size must be between 0 and 32768 bytes."
            return
        }
        resetStatistics()
        isRunning = true
        summary = "Running..."
        startedAt = Date()
        let id = runID
        runTask = Task { [weak self] in await self?.runConfiguredTest(id: id) }
    }

    func sendSingleMessage() {
        guard !isRunning else { return }
        messageCount = 1
        startTest()
    }

    func stopTest() {
        runTask?.cancel()
        runTask = nil
        finishRun(reason: "Stopped", missing: bridge.pendingCount)
        bridge.reset()
        runID &+= 1
    }

    func resetStatistics() {
        runTask?.cancel()
        runTask = nil
        runID &+= 1
        bridge.reset()
        isRunning = false
        statistics = Statistics()
        rttSamples.removeAll()
        startedAt = nil
        summary = "Statistics reset."
        recentEvents.removeAll()
    }

    private func runConfiguredTest(id: UInt64) async {
        let count = max(1, messageCount)
        let interval = sendInterval.nanoseconds(customMilliseconds: customIntervalMilliseconds)
        for _ in 0..<count {
            guard !Task.isCancelled, isRunning, id == runID else { return }
            await sendNextMessage(id: id)
            if let interval {
                do { try await Task.sleep(nanoseconds: interval) } catch { return }
            }
        }
        guard !Task.isCancelled, isRunning, id == runID else { return }
        bridge.finishSubmissions()
    }

    private func sendNextMessage(id: UInt64) async {
        let sequence = nextSequence
        nextSequence &+= 1
        let payload = Self.makePayload(sequence: sequence, size: payloadSize)
        let message = MessageBridge.makeMessage(type: 1, sequence: sequence, payload: payload)
        statistics.messagesAttempted += 1
        refreshElapsedTime()
        do {
            try await bridge.send(message, mode: writeMode)
            guard id == runID, isRunning else { return }
            statistics.messagesSent += 1
            statistics.bytesSent += payload.count
        } catch {
            guard id == runID, isRunning else { return }
            statistics.messagesFailed += 1
            addEvent("Send failed seq \(sequence): \(error.localizedDescription)")
        }
        refreshElapsedTime()
    }

    private func handle(_ event: MessageBridge.Event) {
        switch event {
        case .acknowledged(let ack, let expectedSize, let rtt):
            guard isRunning else { return }
            rttSamples.append(rtt)
            statistics.currentRTT = rtt
            statistics.minimumRTT = min(statistics.minimumRTT ?? rtt, rtt)
            statistics.maximumRTT = max(statistics.maximumRTT ?? rtt, rtt)
            statistics.averageRTT = rttSamples.reduce(0, +) / Double(rttSamples.count)
            if ack.status == .ok && ack.size == expectedSize {
                statistics.acknowledgementsReceived += 1
                statistics.bytesAcknowledged += expectedSize
            } else {
                statistics.corruptMessages += 1
                addEvent("ACK error seq \(ack.sequence): \(ack.status.name), size \(ack.size)")
            }
            refreshElapsedTime()
        case .duplicate(let sequence):
            statistics.duplicateAcknowledgements += 1
            addEvent("Duplicate ACK seq \(sequence)")
        case .unexpected(let sequence):
            statistics.unexpectedAcknowledgements += 1
            addEvent("Unexpected ACK seq \(sequence)")
        case .malformed(let data):
            addEvent("Unparsed ACK/frame: \(data.prefix(16).map { String(format: "%02X", $0) }.joined(separator: " "))")
        case .timedOut(let sequences):
            finishRun(reason: "ACK timeout", missing: sequences.count)
        case .drained:
            finishRun(reason: "Complete", missing: 0)
        }
    }

    private func finishRun(reason: String, missing: Int) {
        guard isRunning else { return }
        isRunning = false
        statistics.messagesMissing = missing
        refreshElapsedTime()
        summary = "\(reason). Sent: \(statistics.messagesSent), ACKed: \(statistics.acknowledgementsReceived), Missing: \(statistics.messagesMissing), Corrupt: \(statistics.corruptMessages)"
        addEvent(summary)
    }

    private func refreshElapsedTime() {
        guard let startedAt else { statistics.elapsedTime = 0; return }
        statistics.elapsedTime = Date().timeIntervalSince(startedAt)
    }

    private func addEvent(_ event: String) {
        recentEvents.append(event)
        if recentEvents.count > 20 { recentEvents.removeFirst(recentEvents.count - 20) }
    }

    private static func makePayload(sequence: UInt32, size: Int) -> Data {
        Data((0..<max(0, size)).map { UInt8(truncatingIfNeeded: sequence &+ UInt32($0 &* 31)) })
    }
}
