import SwiftUI

struct NearbyStationsView: View {
    @StateObject private var viewModel = NearbyStationsViewModel()
    @StateObject private var bluetooth = BluetoothManager()
    @State private var isSendingFreshLiveData = false

    var body: some View {
        List {
            bleDemoSection

            switch viewModel.state {
            case .idle:
                findButtonSection
            case .requestingLocation:
                statusSection(title: "Requesting Location", systemImage: "location", message: "Getting your current location...")
            case .loadingStationMetadata:
                statusSection(title: "Loading Stations", systemImage: "tram", message: "Checking cached CTA station metadata...")
            case .loadingArrivals:
                statusSection(title: "Loading Trains", systemImage: "clock", message: "Fetching CTA arrivals...")
            case .loaded(let stationArrivals, let updatedAt):
                loadedSections(stationArrivals: stationArrivals, updatedAt: updatedAt)
            case .error(let message):
                errorSection(message: message)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Nearby Trains")
        .onDisappear {
            viewModel.stopRefreshing()
        }
    }

    private var bleDemoSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Label(bluetooth.connectionState.title, systemImage: bluetooth.canSend ? "checkmark.circle" : "antenna.radiowaves.left.and.right")
                    .font(.headline)
                Text(bluetooth.connectionState.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button {
                bluetooth.scanAndConnect()
            } label: {
                Label("Connect CTA Tracker", systemImage: "antenna.radiowaves.left.and.right")
            }
            .disabled(bluetooth.connectionState == .scanning || bluetooth.connectionState == .connecting)

            Button {
                bluetooth.disconnect()
            } label: {
                Label("Disconnect", systemImage: "xmark.circle")
            }
            .disabled(bluetooth.connectionState == .disconnected)

            Button {
                bluetooth.sendTestData()
            } label: {
                Label("Send Test Data", systemImage: "paperplane")
            }
            .disabled(!bluetooth.canSend)

            if isSendingFreshLiveData {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Fetching fresh CTA data for BLE...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let payload = bluetooth.lastSentPayload {
                Text(payload)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
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
            Text("BLE Demo")
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
                .disabled(!bluetooth.canSend || livePayloadSource(from: stationArrivals) == nil)
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
        guard bluetooth.canSend, !isSendingFreshLiveData else {
            return
        }

        isSendingFreshLiveData = true
        defer { isSendingFreshLiveData = false }

        guard let stationArrivals = await viewModel.freshArrivalsForBLESend(), bluetooth.canSend else {
            return
        }

        sendLiveData(stationArrivals)
    }

    private func sendLiveData(_ stationArrivals: [StationArrivals]) {
        guard let source = livePayloadSource(from: stationArrivals) else {
            return
        }

        let payload = [
            source.station.station.name,
            cleanDirectionName(source.directions[0].name),
            lineGroups(from: source.directions[0].trains).joined(separator: ";"),
            cleanDirectionName(source.directions[1].name),
            lineGroups(from: source.directions[1].trains).joined(separator: ";")
        ].joined(separator: "|")

        bluetooth.sendPayload(payload)
    }

    private func cleanDirectionName(_ name: String) -> String {
        name.replacingOccurrences(of: "Toward ", with: "")
    }

    private func livePayloadSource(from stationArrivals: [StationArrivals]) -> (station: StationArrivals, directions: [DirectionArrivals])? {
        guard let station = stationArrivals.first(where: { $0.directions.count >= 2 }) else {
            return nil
        }

        return (station, Array(station.directions.prefix(2)))
    }

    private func lineGroups(from trains: [CTAArrival]) -> [String] {
        let routeOrder = orderedRoutes(from: trains)
        let trainsByRoute = Dictionary(grouping: trains.prefix(3)) { train in
            train.route
        }

        return routeOrder.compactMap { route in
            guard let routeTrains = trainsByRoute[route] else {
                return nil
            }

            let etas = routeTrains
                .map(minuteETA)
                .map(String.init)
                .joined(separator: ",")

            return "\(routeName(for: route)):\(routeColorHex(for: route)):\(etas)"
        }
    }

    private func orderedRoutes(from trains: [CTAArrival]) -> [String] {
        var routes: [String] = []
        for train in trains.prefix(3) where !routes.contains(train.route) {
            routes.append(train.route)
        }
        return routes
    }

    private func minuteETA(from train: CTAArrival) -> Int {
        max(0, Int((train.arrivalTime.timeIntervalSinceNow / 60).rounded(.up)))
    }

    private func routeName(for route: String) -> String {
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

    private func routeColorHex(for route: String) -> String {
        switch route.lowercased() {
        case "red": return "C60C30"
        case "blue": return "00A1DE"
        case "brn": return "62361B"
        case "g": return "009B3A"
        case "org": return "F9461C"
        case "p", "pexp": return "522398"
        case "pnk", "pink": return "E27EA6"
        case "y": return "F9E300"
        default: return "FFFFFF"
        }
    }

    private func stationSection(_ stationArrivals: StationArrivals) -> some View {
        Section {
            if stationArrivals.directions.isEmpty {
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

    var body: some View {
        Text(routeName)
            .font(.caption.weight(.bold))
            .foregroundStyle(.white)
            .frame(minWidth: 52, minHeight: 26)
            .background(routeColor, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .accessibilityLabel("Route \(route)")
    }

    private var routeName: String {
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
