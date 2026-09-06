import SwiftUI

struct BLETestView: View {
    @StateObject private var bluetooth: BluetoothService
    @StateObject private var runner: BLETestRunner

    private let sizePresets = [
        ("20 B", 20),
        ("50 B", 50),
        ("100 B", 100),
        ("250 B", 250),
        ("500 B", 500),
        ("1 KB", 1024),
        ("2 KB", 2 * 1024),
        ("5 KB", 5 * 1024),
        ("10 KB", 10 * 1024),
        ("20 KB", 20 * 1024)
    ]

    private let countPresets = [1, 10, 100, 1_000, 10_000]

    init() {
        let bluetooth = BluetoothService()
        _bluetooth = StateObject(wrappedValue: bluetooth)
        _runner = StateObject(wrappedValue: BLETestRunner(bridge: MessageBridge(bluetooth: bluetooth)))
    }

    var body: some View {
        List {
            connectionSection
            controlsSection
            buttonsSection
            statisticsSection
            summarySection
            eventsSection
            debugSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("BLE Test")
    }

    private var connectionSection: some View {
        Section("Connection") {
            Label(bluetooth.connectionState.title, systemImage: bluetooth.canSend ? "checkmark.circle" : "antenna.radiowaves.left.and.right")
                .foregroundStyle(bluetooth.canSend ? .green : .primary)

            LabeledContent("Device", value: bluetooth.connectedDeviceName ?? BluetoothService.deviceName)
            LabeledContent("Max Write Size", value: bluetooth.maximumWriteValueLength.map { "\($0) B" } ?? "Unknown")

            Button {
                bluetooth.scanAndConnect()
            } label: {
                Label("Connect", systemImage: "antenna.radiowaves.left.and.right")
            }
            .disabled(bluetooth.connectionState == .scanning || bluetooth.connectionState == .connecting)

            Button(role: .destructive) {
                bluetooth.disconnect()
            } label: {
                Label("Disconnect", systemImage: "xmark.circle")
            }
            .disabled(bluetooth.connectionState == .disconnected)
        }
    }

    private var controlsSection: some View {
        Section("Controls") {
            Stepper("Message Size: \(byteString(runner.payloadSize))", value: $runner.payloadSize, in: 1...100_000, step: 1)

            PresetGrid(presets: sizePresets) { label, value in
                Button(label) {
                    runner.payloadSize = value
                }
            }

            Picker("Message Count", selection: $runner.messageCount) {
                ForEach(countPresets, id: \.self) { count in
                    Text(count.formatted()).tag(count)
                }
            }

            Stepper("Custom Count: \(runner.messageCount.formatted())", value: $runner.messageCount, in: 1...100_000, step: 1)

            Picker("Send Interval", selection: $runner.sendInterval) {
                ForEach(BLETestRunner.SendInterval.allCases) { interval in
                    Text(interval.rawValue).tag(interval)
                }
            }

            if runner.sendInterval == .custom {
                Stepper("Custom Interval: \(runner.customIntervalMilliseconds) ms", value: $runner.customIntervalMilliseconds, in: 0...10_000, step: 1)
            }

            Picker("BLE Write Mode", selection: $runner.writeMode) {
                ForEach(BLEWriteMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
        }
        .disabled(runner.isRunning)
    }

    private var buttonsSection: some View {
        Section {
            Button {
                runner.startTest()
            } label: {
                Label("Start Test", systemImage: "play.fill")
            }
            .disabled(!bluetooth.canSend || runner.isRunning)

            Button {
                runner.stopTest()
            } label: {
                Label("Stop Test", systemImage: "stop.fill")
            }
            .disabled(!runner.isRunning)

            Button {
                runner.sendSingleMessage()
            } label: {
                Label("Send Single Message", systemImage: "paperplane")
            }
            .disabled(!bluetooth.canSend || runner.isRunning)

            Button(role: .destructive) {
                runner.resetStatistics()
            } label: {
                Label("Reset Statistics", systemImage: "arrow.counterclockwise")
            }
        }
    }

    private var statisticsSection: some View {
        Section("Live Statistics") {
            StatRow("Messages Attempted", runner.statistics.messagesAttempted.formatted())
            StatRow("Messages Sent", runner.statistics.messagesSent.formatted())
            StatRow("ACKs Received", runner.statistics.acknowledgementsReceived.formatted())
            StatRow("Messages Failed", runner.statistics.messagesFailed.formatted())
            StatRow("Messages Missing", runner.statistics.messagesMissing.formatted())
            StatRow("Bytes Sent", byteString(runner.statistics.bytesSent))
            StatRow("Elapsed Time", secondsString(runner.statistics.elapsedTime))
            StatRow("Messages/sec", rateString(runner.statistics.messagesPerSecond))
            StatRow("KB/sec", rateString(runner.statistics.kilobytesPerSecond))
            StatRow("Current RTT", rttString(runner.statistics.currentRTT))
            StatRow("Average RTT", rttString(runner.statistics.averageRTT))
            StatRow("Minimum RTT", rttString(runner.statistics.minimumRTT))
            StatRow("Maximum RTT", rttString(runner.statistics.maximumRTT))
            StatRow("Error Rate", percentageString(runner.statistics.errorRate))
        }
    }

    private var summarySection: some View {
        Section("Summary") {
            Text(runner.summary)
                .font(.callout.monospacedDigit())
                .textSelection(.enabled)
        }
    }

    private var eventsSection: some View {
        Section("Events") {
            if runner.recentEvents.isEmpty {
                Text("No events.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(runner.recentEvents, id: \.self) { event in
                    Text(event)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            }
        }
    }

    private var debugSection: some View {
        Section("BLE Debug Log") {
            Toggle("Show All Discoveries", isOn: $bluetooth.showsAllDebugMessages)

            Button("Clear Log") {
                bluetooth.clearDebugLog()
            }

            ForEach(bluetooth.debugMessages.suffix(12), id: \.self) { message in
                Text(message)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    private func byteString(_ bytes: Int) -> String {
        if bytes >= 1024 {
            return "\(bytes / 1024) KB"
        }
        return "\(bytes) B"
    }

    private func secondsString(_ seconds: TimeInterval) -> String {
        String(format: "%.2f s", seconds)
    }

    private func rateString(_ rate: Double) -> String {
        String(format: "%.2f", rate)
    }

    private func rttString(_ rtt: TimeInterval?) -> String {
        guard let rtt else {
            return "-"
        }
        return String(format: "%.1f ms", rtt * 1000)
    }

    private func percentageString(_ value: Double) -> String {
        String(format: "%.2f%%", value * 100)
    }
}

private struct PresetGrid<Content: View>: View {
    let presets: [(String, Int)]
    let content: (String, Int) -> Content

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 8)], alignment: .leading, spacing: 8) {
            ForEach(presets, id: \.1) { preset in
                content(preset.0, preset.1)
                    .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct StatRow: View {
    let title: String
    let value: String

    init(_ title: String, _ value: String) {
        self.title = title
        self.value = value
    }

    var body: some View {
        LabeledContent(title, value: value)
            .font(.callout.monospacedDigit())
    }
}

#Preview {
    NavigationStack {
        BLETestView()
    }
}
