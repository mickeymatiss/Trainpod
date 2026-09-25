#if DEBUG
import Combine
import CoreLocation
import Foundation

@MainActor
final class ArrivalComparisonViewModel: ObservableObject {
    @Published private(set) var result: TransitArrivalResult?
    @Published private(set) var rows: [ArrivalComparisonRow] = []
    @Published private(set) var snapshot: TransitRealtimeSnapshot?
    @Published private(set) var legacyCompletedAt: Date?
    @Published private(set) var normalizedCompletedAt: Date?
    @Published private(set) var legacyError: String?
    @Published private(set) var normalizedError: String?
    @Published private(set) var resolutionError: String?
    @Published private(set) var diagnostics: [String: Int] = [:]
    @Published private(set) var legacyLoading = false
    @Published private(set) var normalizedLoading = false
    @Published private(set) var fallbackUsed = false
    var isRefreshing: Bool { legacyLoading || normalizedLoading }
    var summary: ArrivalComparisonSummary { ArrivalComparisonSummary(rows: rows) }
    var system: TransitSystemID { result?.context.systemId ?? TransitAgency.selected.systemID }
    var stationIDs: [String] { result?.context.stationIds ?? [] }
    private var pinnedStation: StationArrivals?
    private var pinnedSystem: TransitSystemID?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var subscription: AnyCancellable?

    init(station: StationArrivals? = nil, system: TransitSystemID? = nil) {
        pinnedStation = station; pinnedSystem = system
        subscription = TransitServingCoordinator.shared.$latestComparison.sink { [weak self] record in
            guard let self, let record, record.requestId == self.result?.id else { return }
            self.apply(record)
        }
    }

    func stop() {
        task?.cancel(); task = nil; generation = UUID()
        normalizedLoading = false; legacyLoading = false
    }

    func useRealLocation() {
        TransitLocationSimulator.shared.useRealLocation()
        pinnedStation = nil; pinnedSystem = nil
        refresh()
    }

    func randomTest(system: TransitSystemID) {
        guard !isRefreshing else { return }
        TransitLocationSimulator.shared.generate(system: system)
        pinnedStation = nil; pinnedSystem = nil
        refresh()
    }

    func refresh() {
        guard !isRefreshing else { return }
        let token = UUID(); generation = token
        let selected = TransitAgency.selected.systemID
        if pinnedSystem != selected { pinnedStation = nil; pinnedSystem = nil }
        let revision = TransitLocationSource.shared.revision
        result = nil; rows = []; snapshot = nil
        normalizedError = nil; legacyError = nil; resolutionError = nil; diagnostics = [:]
        legacyCompletedAt = nil; normalizedCompletedAt = nil; fallbackUsed = false
        normalizedLoading = true
        task = Task {
            defer { if self.generation == token { self.normalizedLoading = false } }
            do {
                // Only this explicit developer action waits for a first manifest.
                if TransitManifestManager.shared.cachedManifest(for: selected) == nil {
                    await TransitManifestManager.shared.refreshIfChanged(systemId: selected)
                }
                let location = try await TransitLocationSource.shared.currentLocation(system: selected)
                try Task.checkCancellation()
                var query = TransitQueryContext(systemId: selected, latitude: location.coordinate.latitude,
                    longitude: location.coordinate.longitude, locationLabel: TransitLocationSource.shared.label)
                if let pinnedStation, let manifest = TransitManifestManager.shared.cachedManifest(for: selected) {
                    query.stationIds = LegacyArrivalAdapter.stationIDs(for: pinnedStation.station, system: selected, manifest: manifest).sorted()
                }
                let served = try await TransitServingCoordinator.shared.serve(query)
                try Task.checkCancellation()
                guard generation == token, revision == TransitLocationSource.shared.revision else { return }
                result = served; snapshot = served.snapshot; fallbackUsed = served.source == .legacyFallback
                normalizedError = served.cloudError
                normalizedCompletedAt = served.source == .cloud ? served.completedAt : nil
                legacyCompletedAt = served.source == .legacyFallback ? served.completedAt : nil
                legacyLoading = TransitServingCoordinator.shared.checkingRequestId == served.id
                if let snapshot = served.snapshot, let manifest = served.manifest {
                    let scope = Set(served.context.stationIds)
                    let resolved = try await Task.detached(priority: .utility) {
                        try RealtimeResolver.resolve(snapshot: snapshot, manifest: manifest)
                    }.value
                    guard generation == token else { return }
                    diagnostics = resolved.diagnostics
                    let arrivals = ArrivalComparison.normalized(resolved.arrivals.filter { scope.contains($0.stationId) })
                    rows = ArrivalComparison.rows(legacy: [], normalized: arrivals)
                }
                if let record = TransitServingCoordinator.shared.latestComparison, record.requestId == served.id { apply(record) }
                else if !selected.supportsLegacySource { legacyError = "Not available — \(selected.rawValue.uppercased()) uses cloud arrivals only." }
                else if !legacyLoading { legacyError = "Another reliability check is in flight. Refresh after it completes." }
                if served.context.locationLabel == "Simulated location" {
                    FileLogger.shared.log("[TRANSIT] dev_random_test_completed systemId=\(selected.rawValue) fallback=\(fallbackUsed)")
                }
            } catch {
                guard generation == token, !Task.isCancelled else { return }
                if let failure = error as? TransitServingFailure {
                    normalizedError = failure.cloudError; legacyError = failure.legacyError; fallbackUsed = true
                } else { resolutionError = error.localizedDescription }
            }
        }
    }

    private func apply(_ record: TransitReliabilityComparison) {
        rows = record.rows
        legacyCompletedAt = record.legacyCompletedAt
        normalizedCompletedAt = record.cloudCompletedAt
        legacyError = record.legacyError; normalizedError = record.cloudError
        fallbackUsed = record.fallbackUsed
        legacyLoading = false
    }
}
#endif
