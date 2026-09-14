import SwiftUI

struct NearbyStationsView: View {
    @StateObject private var viewModel = NearbyStationsViewModel()
    @StateObject private var bluetooth: BluetoothService
    @StateObject private var bridge: MessageBridge
    @StateObject private var refreshHandler: RefreshRequestHandler
    @StateObject private var liveProvider: LiveTransitProvider
    @State private var isSendingFreshLiveData = false
    @State private var showingLogs = false
    @AppStorage(TransitAgency.preferenceKey) private var agency = TransitAgency.cta.rawValue
    @AppStorage(MTALocationMode.preferenceKey) private var mtaLocationMode = MTALocationMode.current.rawValue

    init() {
        let runtime = BLERuntime.shared
        _liveProvider = StateObject(wrappedValue: runtime.provider)
        _bluetooth = StateObject(wrappedValue: runtime.bluetooth)
        _bridge = StateObject(wrappedValue: runtime.bridge)
        _refreshHandler = StateObject(wrappedValue: runtime.refreshHandler)
    }

    var body: some View {
        List {
            Section("Transit system") {
                Picker("Agency", selection: $agency) {
                    ForEach(TransitAgency.allCases) { Text($0.rawValue).tag($0.rawValue) }
                }.pickerStyle(.segmented)
                .disabled(isSendingFreshLiveData || bridge.isSending)
                if agency == "MTA" {
                    Picker("MTA location", selection: $mtaLocationMode) {
                        ForEach(MTALocationMode.allCases) { Text($0.rawValue).tag($0.rawValue) }
                    }.pickerStyle(.menu)
                    .disabled(isSendingFreshLiveData || bridge.isSending)
                    if let testMode = MTALocationMode(rawValue: mtaLocationMode), testMode != .current {
                        Label("Testing \(testMode.rawValue)", systemImage: "mappin.and.ellipse")
                            .font(.subheadline)
                        Text("App and device refreshes use this test location instead of your GPS location.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text("Next nine trains at each of your two closest MTA stations, grouped by service direction. Distances are straight-line distances.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            bleDemoSection

            switch viewModel.state {
            case .idle:
                findButtonSection
            case .requestingLocation:
                statusSection(title: "Requesting Location", systemImage: "location", message: "Getting your current location...")
            case .loadingStationMetadata:
                statusSection(title: "Loading Stations", systemImage: "tram", message: "Loading station locations...")
            case .loadingArrivals:
                statusSection(title: "Loading Trains", systemImage: "clock", message: "Fetching arrivals...")
            case .loaded(let stationArrivals, let updatedAt):
                loadedSections(stationArrivals: stationArrivals, updatedAt: updatedAt)
            case .error(let message):
                errorSection(message: message)
            }
        }
        .listStyle(.insetGrouped)
        .onChange(of: agency) { _, _ in viewModel.findNearbyTrains() }
        .onChange(of: mtaLocationMode) { _, _ in
            if agency == "MTA" { viewModel.findNearbyTrains() }
        }
        .navigationTitle("Nearby Trains")
        .sheet(isPresented: $showingLogs) { LogShareSheet() }
        .onDisappear {
            viewModel.stopRefreshing()
        }
    }

    private var bleDemoSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Label(bluetooth.connectionState.title, systemImage: bluetooth.canSend ? "checkmark.circle" : "antenna.radiowaves.left.and.right")
                    .font(.headline)
                Text(bluetooth.connectionMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button {
                bluetooth.scanAndConnect()
            } label: {
                Label("Connect TrainPod", systemImage: "antenna.radiowaves.left.and.right")
            }
            .disabled(bluetooth.connectionState == .scanning || bluetooth.connectionState == .connecting)

            Button {
                bluetooth.disconnect()
            } label: {
                Label("Disconnect", systemImage: "xmark.circle")
            }
            .disabled(bluetooth.connectionState == .disconnected)

            Button {
                sendTransitPayload(TransitMessage.dummyPayload)
            } label: {
                Label("Send Test Data", systemImage: "paperplane")
            }
            .disabled(!bluetooth.canSend)

            Text(refreshHandler.status).font(.caption)
            Button("Share Logs", systemImage: "square.and.arrow.up") {
                Task {
                    await FileLogger.shared.flush()
                    showingLogs = true
                }
            }
            Button("Clear Logs", role: .destructive) { FileLogger.shared.clearLogs() }
            DisclosureGroup("Connection Lifecycle Log") {
                ForEach(Array(bluetooth.lifecycleDiagnostics.enumerated()), id: \.offset) { _, entry in
                    Text(entry).font(.caption2.monospaced()).textSelection(.enabled)
                }
            }
            Button("Enable Background Location") { liveProvider.enableBackgroundLocation() }
            Text("For locked-phone refreshes, allow Always location access. The device requests data automatically; recent transit results are reused for 30 seconds.")
                .font(.caption).foregroundStyle(.secondary)
            LabeledContent("Device refresh requests", value: "\(refreshHandler.requestCount)")
            LabeledContent("Last request backgrounded", value: refreshHandler.lastRequestWasBackgrounded ? "Yes" : "No")
            if let date = refreshHandler.lastRequest {
                LabeledContent("Last device request", value: date.formatted(date: .abbreviated, time: .standard))
            }

            if isSendingFreshLiveData {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Preparing station data for BLE...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let payload = bridge.lastSentMessage {
                Text(String(decoding: payload, as: UTF8.self))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }

            if let error = bridge.lastError {
                Text(error).font(.caption).foregroundStyle(.red)
            }

            if !bluetooth.debugMessages.isEmpty {
                DisclosureGroup("BLE Debug Log") {
                    Toggle("Show All Discoveries", isOn: $bluetooth.showsAllDebugMessages)

                    Button("Clear Log") {
                        bluetooth.clearDebugLog()
                    }

                    ForEach(bluetooth.debugMessages.suffix(16), id: \.self) { message in
                        Text(message)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
        } header: {
            Text("Connection & debugging")
        }
    }

    private var findButtonSection: some View {
        Section {
            Button {
                viewModel.findNearbyTrains()
            } label: {
                Label("Find Nearby Trains", systemImage: "location.magnifyingglass")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    private func statusSection(title: String, systemImage: String, message: String) -> some View {
        Section {
            HStack(spacing: 12) {
                ProgressView()
                VStack(alignment: .leading, spacing: 3) {
                    Label(title, systemImage: systemImage)
                        .font(.headline)
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 6)
        }
    }

    private func loadedSections(stationArrivals: [StationArrivals], updatedAt: Date) -> some View {
        Group {
            Section {
                Button {
                    viewModel.findNearbyTrains()
                } label: {
                    Label("Find Nearby Trains", systemImage: "location.magnifyingglass")
                }

                Button {
                    sendFreshLiveData()
                } label: {
                    Label("Send Live Data", systemImage: "paperplane.fill")
                }
                .disabled(!bluetooth.canSend || LiveTransitFormatter.livePayloadSource(from: stationArrivals) == nil)
            } footer: {
                Text("Updated \(updatedAt.formatted(date: .omitted, time: .shortened)). Arrivals refresh every minute while this page is open.")
            }

            ForEach(stationArrivals) { station in
                stationSection(station)
            }
        }
    }

    private func sendFreshLiveData() {
        Task {
            await sendFreshLiveDataIfAvailable()
        }
    }

    private func sendFreshLiveDataIfAvailable() async {
        guard bluetooth.canSend, !bridge.isSending, !isSendingFreshLiveData else {
            return
        }

        isSendingFreshLiveData = true
        defer { isSendingFreshLiveData = false }

        let stationArrivals = await viewModel.freshArrivalsForBLESend()
        guard bluetooth.canSend, !bridge.isSending else {
            return
        }

        sendLiveData(stationArrivals ?? [])
    }

    private func sendLiveData(_ stationArrivals: [StationArrivals]) {
        let data = (try? LiveTransitFormatter.payload(from: stationArrivals)) ?? TransitMessage.unavailablePayload
        sendTransitPayload(String(decoding: data, as: UTF8.self))
    }

    private func sendTransitPayload(_ payload: String) {
        Task {
            guard !bridge.isSending else {
                FileLogger.shared.log("[REFRESH] BLE payload already sending; foreground send coalesced")
                return
            }
            do { try await bridge.send(TransitMessage.encode(payload), mode: bluetooth.preferredWriteMode) }
            catch { /* MessageBridge publishes the send error for this view. */ }
        }
    }

    private func stationSection(_ stationArrivals: StationArrivals) -> some View {
        Section {
            if stationArrivals.station.id.hasPrefix("MTA-") {
                ForEach(stationArrivals.directions) { platform in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(platform.name).font(.subheadline.weight(.semibold))
                        if platform.trains.isEmpty {
                            Text("No trains in this direction among the next nine.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(platform.trains) { train in
                            HStack {
                                RouteBadge(route: train.route, isMTA: true)
                                Spacer()
                                Text("\(max(0, Int((train.arrivalTime.timeIntervalSinceNow / 60).rounded(.up)))) min")
                                    .monospacedDigit()
                            }
                        }
                    }.padding(.vertical, 5)
                }
                if let meters = stationArrivals.distanceMeters {
                    let distance = LiveTransitFormatter.distanceLabel(meters)
                    Text("\(distance.value) \(distance.unit) away").font(.caption)
                }
            } else if stationArrivals.directions.isEmpty {
                Text("No upcoming trains found.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(stationArrivals.directions) { direction in
                    DirectionArrivalsView(direction: direction)
                }
            }
        } header: {
            Text(stationArrivals.station.name)
        } footer: {
            Text("Station ID \(stationArrivals.station.mapID)")
        }
    }

    private func errorSection(message: String) -> some View {
        Section {
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)

            Button {
                viewModel.findNearbyTrains()
            } label: {
                Label("Try Again", systemImage: "arrow.clockwise")
            }
        }
    }
}

private struct LogShareSheet: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [FileLogger.shared.fileURL], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

private struct DirectionArrivalsView: View {
    let direction: DirectionArrivals

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(direction.name)
                .font(.subheadline.weight(.semibold))

            if lineGroups.isEmpty {
                Text("No upcoming trains.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(lineGroups) { group in
                    TrainLineGroupView(group: group)
                }
            }
        }
        .padding(.vertical, 5)
    }

    private var lineGroups: [TrainLineGroup] {
        let visibleTrains = Array(direction.trains.prefix(3))
        var groups: [TrainLineGroup] = []

        for train in visibleTrains {
            let eta = max(0, Int((train.arrivalTime.timeIntervalSinceNow / 60).rounded(.up)))

            if let index = groups.firstIndex(where: { $0.route == train.route }) {
                groups[index].etas.append(eta)
            } else {
                groups.append(TrainLineGroup(route: train.route, etas: [eta]))
            }
        }

        return groups
    }
}

private struct TrainLineGroup: Identifiable {
    let route: String
    var etas: [Int]

    var id: String { route }
}

private struct TrainLineGroupView: View {
    let group: TrainLineGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            RouteBadge(route: group.route)

            HStack(spacing: 12) {
                ForEach(group.etas, id: \.self) { eta in
                    Text("\(eta) min")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct RouteBadge: View {
    let route: String
    var isMTA = false

    var body: some View {
        Text(routeName)
            .font(.caption.weight(.bold))
            .foregroundStyle(.white)
            .frame(minWidth: 52, minHeight: 26)
            .background(routeColor, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .accessibilityLabel("Route \(route)")
    }

    private var routeName: String {
        if isMTA { return route.uppercased() }
        switch route.lowercased() {
        case "g": return "Green"
        case "brn": return "Brown"
        case "org": return "Orange"
        case "p": return "Purple"
        case "pexp": return "Purple Express"
        case "pnk", "pink": return "Pink"
        case "y": return "Yellow"
        default: return route.capitalized
        }
    }

    private var routeColor: Color {
        if isMTA {
            let rgb = UInt32(MTARouteStyle.hex(route), radix: 16) ?? 0x808183
            return Color(red: Double((rgb >> 16) & 255) / 255,
                         green: Double((rgb >> 8) & 255) / 255,
                         blue: Double(rgb & 255) / 255)
        }
        switch route.lowercased() {
        case "red": return .red
        case "blue": return .blue
        case "brn": return .brown
        case "g": return .green
        case "org": return .orange
        case "p", "pexp": return .purple
        case "pnk", "pink": return .pink
        case "y": return .yellow
        default: return .indigo
        }
    }
}

#Preview {
    NavigationStack {
        NearbyStationsView()
    }
}
