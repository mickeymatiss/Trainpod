#if DEBUG
import SwiftUI

struct ArrivalComparisonView: View {
    @ObservedObject private var simulator = TransitLocationSimulator.shared
    @AppStorage(TransitAgency.preferenceKey) private var agency = TransitAgency.cta.rawValue
    @StateObject private var model: ArrivalComparisonViewModel

    init(station: StationArrivals? = nil, system: TransitSystemID? = nil) {
        _model = StateObject(wrappedValue: ArrivalComparisonViewModel(station: station, system: system))
    }

    var body: some View {
        List {
            Section("Location Simulation") {
                Picker("System", selection: $agency) {
                    ForEach(TransitAgency.allCases) { system in
                        Text("\(system.cityName) / \(system.systemID.rawValue.uppercased())").tag(system.rawValue)
                    }
                }.disabled(model.isRefreshing)
                Picker("Sampling square", selection: $simulator.squareMiles) {
                    ForEach([2, 4, 6], id: \.self) { Text("\($0) miles").tag($0) }
                }.disabled(model.isRefreshing)
                Button("Use Real Location") { model.useRealLocation() }.disabled(model.isRefreshing)
                HStack {
                    Button("Simulate Chicago") { model.randomTest(system: .cta) }
                    Spacer()
                    Button("Simulate NYC") { model.randomTest(system: .nyc) }
                }.buttonStyle(.borderless).disabled(model.isRefreshing)
                Button("Simulate Bay Area") { model.randomTest(system: .bart) }.disabled(model.isRefreshing)
                Button("Simulate Boston") { model.randomTest(system: .mbta) }.disabled(model.isRefreshing)
                Button("Random Test", systemImage: "dice") {
                    model.randomTest(system: TransitAgency.selected.systemID)
                }.disabled(model.isRefreshing)
                if let coordinate = simulator.coordinate, let system = simulator.system {
                    Text("Simulated \(system.rawValue.uppercased()): \(coordinate.latitude, specifier: "%.6f"), \(coordinate.longitude, specifier: "%.6f")")
                        .font(.caption.monospaced()).textSelection(.enabled)
                    Text("Session-only override also applies to device requests in this Debug build. Use Real Location to turn it off.")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            Section("Station / Serving") {
                LabeledContent("System", value: model.system.rawValue.uppercased())
                if let result = model.result {
                    Text(result.context.locationLabel)
                    Text("\(result.context.latitude, specifier: "%.6f"), \(result.context.longitude, specifier: "%.6f")")
                        .font(.caption.monospaced()).textSelection(.enabled)
                    ForEach(result.stations) { station in
                        Text("\(station.station.name) · \(station.station.mapID)")
                    }
                    LabeledContent("Serving source", value: result.source == .cloud ? "CLOUD" : "LEGACY FALLBACK")
                    LabeledContent("Served arrivals", value: String(result.stations.reduce(0) { $0 + $1.directions.reduce(0) { $0 + $1.trains.count } }))
                }
                Text(model.system.supportsLegacySource ? "Cloud serves first. Direct-provider validation runs independently; differences do not decide which source is correct." : "\(model.system.rawValue.uppercased()) uses cloud arrivals. No legacy provider is called.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Cloud / Source health") {
                health("Cloud", loading: model.normalizedLoading, error: model.normalizedError, at: model.normalizedCompletedAt)
                health("Direct source", loading: model.legacyLoading, error: model.legacyError, at: model.legacyCompletedAt)
                if model.fallbackUsed { Label("LEGACY FALLBACK", systemImage: "arrow.uturn.backward").foregroundStyle(.orange) }
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    if let snapshot = model.snapshot {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Source age: \(Int(snapshot.sourceAge(at: context.date)))s")
                            Text("Generated age: \(Int(snapshot.generatedAge(at: context.date)))s")
                            if snapshot.sourceAge(at: context.date) >= 180 {
                                Label("STALE", systemImage: "exclamationmark.triangle.fill").font(.headline).foregroundStyle(.red)
                            }
                        }.monospacedDigit()
                    }
                }
                if let error = model.resolutionError { Text(error).foregroundStyle(.orange) }
            }
            Section("Comparison") {
                if model.system.supportsLegacySource {
                    let summary = model.summary
                    Text("Matched: \(summary.matched) · Source only: \(summary.legacyOnly) · Cloud only: \(summary.normalizedOnly)")
                    Text("Median |Δ|: \(duration(summary.medianAbsoluteDelta)) · Max |Δ|: \(duration(summary.maxAbsoluteDelta))")
                    Text("Destination mismatches: \(summary.destinationMismatches) · Platform mismatches: \(summary.platformMismatches)")
                    Text("Positive Δ means cloud predicts later. Times use your phone’s timezone. Existing direct-source truncation and independent fetch times can produce differences.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("\(model.system.rawValue.uppercased()) cloud arrivals are shown below. Direct-source comparison and fallback are unavailable.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            ForEach(Array(Set(model.rows.map(\.group))).sorted(), id: \.self) { group in
                Section(group) { ForEach(model.rows.filter { $0.group == group }) { comparisonRow($0) } }
            }
            if !model.diagnostics.isEmpty {
                Section("Snapshot reference diagnostics") {
                    ForEach(model.diagnostics.keys.sorted(), id: \.self) { key in
                        LabeledContent(key, value: String(model.diagnostics[key, default: 0]))
                    }
                }
            }
        }
        .navigationTitle("Arrival Comparison")
        .toolbar { Button("Refresh", systemImage: "arrow.clockwise") { model.refresh() }.disabled(model.isRefreshing) }
        .task { model.refresh() }
        .onDisappear { model.stop() }
    }

    private func health(_ name: String, loading: Bool, error: String?, at date: Date?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(name): \(loading ? "Fetching…" : error ?? (date == nil ? "Unavailable" : "OK"))")
                .foregroundStyle(error == nil ? Color.primary : Color.orange)
            if let date { Text("Fetch completed: \(time(date))").font(.caption).monospacedDigit() }
        }
    }

    private func comparisonRow(_ row: ArrivalComparisonRow) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(row.arrival.routeName ?? row.arrival.routeId).font(.headline)
                Text(row.arrival.routeId).font(.caption.monospaced()).foregroundStyle(.secondary)
                Spacer()
                Text(model.system.supportsLegacySource ? row.match.rawValue : "CLOUD").font(.caption2.weight(.semibold))
                    .foregroundStyle(row.deltaSeconds == nil ? Color.orange : Color.secondary)
            }
            Text(row.normalized?.destination ?? row.legacy?.destination ?? "Destination unavailable")
                .font(.subheadline)
            HStack(alignment: .top) {
                timeColumn("Legacy", row.legacy?.arrivalAt)
                Spacer()
                timeColumn("Normalized", row.normalized?.arrivalAt)
                Spacer()
                VStack(alignment: .trailing) {
                    Text("Δ").font(.caption).foregroundStyle(.secondary)
                    Text(row.deltaSeconds.map(ArrivalComparison.signedDelta) ?? "—").monospacedDigit()
                }
            }
            Text("Direction \(row.normalized?.direction ?? row.legacy?.direction ?? "?") · Station \(row.arrival.stationId ?? "?") · Trip \(row.legacy?.tripId ?? "?") / \(row.normalized?.tripId ?? "?")")
                .font(.caption2.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            if let note = row.legacy?.identityNote { Text(note).font(.caption).foregroundStyle(.orange) }
        }.padding(.vertical, 4)
    }

    private func timeColumn(_ label: String, _ date: Date?) -> some View {
        VStack(alignment: .leading) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(date.map(time) ?? "—").monospacedDigit()
        }
    }
    private func time(_ date: Date) -> String { date.formatted(.dateTime.hour().minute().second()) }
    private func duration(_ value: TimeInterval?) -> String { value.map { String(format: "%.1fs", $0) } ?? "—" }
}
#endif
