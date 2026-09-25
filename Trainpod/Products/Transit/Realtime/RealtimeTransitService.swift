import Foundation

/// Screen-owned, memory-only shadow state. Nothing here participates in production transit.
@MainActor
final class RealtimeTransitService {
    private(set) var snapshot: TransitRealtimeSnapshot?
    private(set) var fetchedAt: Date?
    private(set) var lastError: String?
    private let client: any RealtimeTransitFetching
    private var generation = UUID()

    init(client: (any RealtimeTransitFetching)? = nil) {
        self.client = client ?? RealtimeTransitClient()
    }

    func refresh(systemId: TransitSystemID) async {
        let token = UUID()
        generation = token
        if snapshot?.systemId != systemId.rawValue { snapshot = nil; fetchedAt = nil }
        lastError = nil
        FileLogger.shared.log("[SHADOW] realtime_shadow_fetch_started systemId=\(systemId.rawValue)")
        do {
            let candidate = try await client.fetchSnapshot(systemId: systemId)
            try Task.checkCancellation()
            try RealtimeResolver.validate(candidate, systemId: systemId)
            guard generation == token else { return }
            snapshot = candidate
            fetchedAt = Date()
            FileLogger.shared.log("[SHADOW] realtime_shadow_fetch_success systemId=\(systemId.rawValue) stations=\(candidate.stations.count)")
            if candidate.sourceAge() >= 180 {
                FileLogger.shared.log("[SHADOW] realtime_shadow_stale systemId=\(systemId.rawValue) age=\(Int(candidate.sourceAge()))")
            }
        } catch {
            guard generation == token else { return }
            lastError = error.localizedDescription
            FileLogger.shared.log("[SHADOW] realtime_shadow_fetch_failed systemId=\(systemId.rawValue) code=\((error as NSError).code)")
        }
    }
}
