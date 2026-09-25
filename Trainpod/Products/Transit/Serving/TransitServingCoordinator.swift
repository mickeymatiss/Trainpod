import Combine
import Foundation

/// Source migration boundary. Returning cloud data never awaits direct-provider validation.
@MainActor
final class TransitServingCoordinator: ObservableObject {
    static let shared = TransitServingCoordinator()
    @Published private(set) var latestResult: TransitArrivalResult?
    @Published private(set) var latestComparison: TransitReliabilityComparison?
    @Published private(set) var checkingRequestId: UUID?
    private let cloud = CloudTransitArrivalSource()
    private let legacy = LegacyTransitArrivalSource()
    private var validationTask: Task<Void, Never>?

    func serve(_ context: TransitQueryContext) async throws -> TransitArrivalResult {
        // Cloud-only systems need their manifest before their first request can be served.
        if !context.systemId.supportsLegacySource,
           TransitManifestManager.shared.cachedManifest(for: context.systemId) == nil {
            await TransitManifestManager.shared.refreshIfChanged(systemId: context.systemId)
        }
        let manifest = TransitManifestManager.shared.cachedManifest(for: context.systemId)
        var query = context
        if let manifest, query.stationIds.isEmpty {
            query.stationIds = TransitStationSelection.select(query, manifest: manifest).map(\.id)
        }
        do {
            var result = try await cloud.arrivals(for: query, manifest: manifest)
            try Task.checkCancellation()
            // Preserve the existing device capacity/serialization safeguards before committing to cloud.
            result.payload = try LiveTransitFormatter.payload(from: result.stations)
            latestResult = result
            FileLogger.shared.log("[TRANSIT] cloud_eta_served systemId=\(query.systemId.rawValue) stations=\(query.stationIds.joined(separator: ",")) sourceAge=\(Int(result.snapshot?.sourceAge() ?? 0))")
            startValidation(result, direct: nil)
            return result
        } catch {
            try Task.checkCancellation()
            let reason = error.localizedDescription
            guard query.systemId.supportsLegacySource else {
                FileLogger.shared.log("[TRANSIT] cloud_eta_failed systemId=\(query.systemId.rawValue) fallbackAvailable=false")
                throw CloudServingError.unavailable("\(query.systemId.rawValue.uppercased()) cloud arrivals unavailable: \(reason)")
            }
            let event = (error as? CloudServingError) == .stale ? "cloud_stale_fallback" : "cloud_eta_failed"
            FileLogger.shared.log("[TRANSIT] \(event) systemId=\(query.systemId.rawValue)")
            do {
                let direct = try await legacy.arrivals(for: query, manifest: manifest)
                try Task.checkCancellation()
                var result = TransitArrivalResult(context: query, stations: direct.stations, completedAt: direct.completedAt,
                    source: .legacyFallback, manifest: manifest, snapshot: cloud.lastSnapshot(for: query.systemId), cloudError: reason)
                result.payload = try LiveTransitFormatter.payload(from: result.stations)
                latestResult = result
                FileLogger.shared.log("[TRANSIT] legacy_fallback_used systemId=\(query.systemId.rawValue)")
                startValidation(result, direct: direct)
                return result
            } catch {
                recordFailure(context: query, cloudError: reason, legacyError: error.localizedDescription)
                throw TransitServingFailure(cloudError: reason, legacyError: error.localizedDescription)
            }
        }
    }

    private func startValidation(_ result: TransitArrivalResult, direct: TransitArrivalResult?) {
        // A simple in-flight guard bounds upstream work if UI/device requests overlap.
        guard result.context.systemId.supportsLegacySource, validationTask == nil else { return }
        checkingRequestId = result.id
        validationTask = Task(priority: .background) {
            await Task.yield()
            defer { self.validationTask = nil; self.checkingRequestId = nil }
            FileLogger.shared.log("[TRANSIT] reliability_check_started systemId=\(result.context.systemId.rawValue)")
            var legacyResult = direct
            var legacyError: String?
            if legacyResult == nil {
                do { legacyResult = try await self.legacy.arrivals(for: result.context, manifest: result.manifest) }
                catch { legacyError = error.localizedDescription }
            }
            let old = legacyResult?.stations.flatMap {
                LegacyArrivalAdapter.arrivals($0, system: result.context.systemId, manifest: result.manifest)
            } ?? []
            let snapshot = result.snapshot, manifest = result.manifest
            let scope = Set(result.context.stationIds)
            let comparison = await Task.detached(priority: .background) {
                let resolved = snapshot.flatMap { snapshot in
                    manifest.flatMap { try? RealtimeResolver.resolve(snapshot: snapshot, manifest: $0) }
                }
                let new = ArrivalComparison.normalized(resolved?.arrivals.filter { scope.contains($0.stationId) } ?? [])
                let rows = ArrivalComparison.rows(legacy: old, normalized: new)
                return (rows, ArrivalComparisonSummary(rows: rows))
            }.value
            let record = TransitReliabilityComparison(requestId: result.id, systemId: result.context.systemId,
                stationIds: result.context.stationIds, comparedAt: Date(), rows: comparison.0, summary: comparison.1,
                cloudSourceAgeSeconds: snapshot.map { Int($0.sourceAge()) }, cloudError: result.cloudError,
                legacyError: legacyError, legacyCompletedAt: legacyResult?.completedAt,
                cloudCompletedAt: result.source == .cloud ? result.completedAt : nil,
                fallbackUsed: result.source == .legacyFallback)
            self.latestComparison = record
            FileLogger.shared.log("[TRANSIT] \(legacyError == nil ? "reliability_check_completed" : "reliability_check_failed") systemId=\(record.systemId.rawValue) matched=\(record.summary.matched) cloudOnly=\(record.summary.normalizedOnly) legacyOnly=\(record.summary.legacyOnly) fallback=\(record.fallbackUsed)")
        }
    }

    private func recordFailure(context: TransitQueryContext, cloudError: String, legacyError: String) {
        latestComparison = TransitReliabilityComparison(requestId: UUID(), systemId: context.systemId,
            stationIds: context.stationIds, comparedAt: Date(), rows: [], summary: ArrivalComparisonSummary(rows: []),
            cloudSourceAgeSeconds: cloud.lastSnapshot(for: context.systemId).map { Int($0.sourceAge()) },
            cloudError: cloudError, legacyError: legacyError, legacyCompletedAt: nil, cloudCompletedAt: nil, fallbackUsed: true)
    }
}
