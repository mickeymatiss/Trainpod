import CoreLocation
import Foundation

/// Shared API results, independent of connection state and BLE send success.
@MainActor
final class TransitDataCache {
    static let shared = TransitDataCache()
    static let freshnessInterval: TimeInterval = 30

    struct CachedTransitData {
        let payload: Data
        let arrivals: [StationArrivals]
        let fetchedAt: Date
        let context: [String]
    }

    private(set) var latest: CachedTransitData?
    private var inFlight: [String: Task<CachedTransitData, Error>] = [:]
    private var lastLocation: CLLocation?
    private let client = CTAClient()

    func rememberLocation(_ fix: CLLocation) { lastLocation = fix }

    var recentLocation: CLLocation? {
        guard let fix = lastLocation, fix.horizontalAccuracy >= 0,
              fix.horizontalAccuracy <= 1000,
              (0..<Self.freshnessInterval).contains(-fix.timestamp.timeIntervalSinceNow) else { return nil }
        return fix
    }

    func result(for stations: [CTAStation]) async throws -> CachedTransitData {
        // Ordered IDs preserve the nearest-station preference and isolate agency/context.
        let context = ["CTA", "TP2-complete"] + stations.map(\.mapID)
        let key = context.joined(separator: ":")
        if let cached = latest {
            let age = Date().timeIntervalSince(cached.fetchedAt)
            FileLogger.shared.log("[CACHE] age=\(Int(age))s contextMatches=\(cached.context == context)")
            if cached.context == context, age >= 0, age < Self.freshnessInterval {
                FileLogger.shared.log("[CACHE] Serving cached transit data")
                return cached
            }
        } else {
            FileLogger.shared.log("[CACHE] No cached transit result")
        }
        if let task = inFlight[key] {
            FileLogger.shared.log("[CACHE] Transit API refresh already in progress; coalescing request")
            return try await task.value
        }
        let task = Task { @MainActor in
            FileLogger.shared.log("[CACHE] Starting transit API refresh")
            // Conservative age: fetching the second station must not freshen the first.
            let fetchedAt = Date()
            var results: [StationArrivals] = []
            for station in stations {
                do {
                    let trains = try await self.client.fetchArrivals(for: station, maxArrivals: 60, timeout: 5)
                    results.append(NearbyStationsViewModel.groupArrivals(trains, for: station))
                } catch {
                    try Task.checkCancellation()
                    FileLogger.shared.log("[CACHE] Failed station excluded code=\((error as NSError).code)")
                }
            }
            let payload = try LiveTransitFormatter.payload(from: results)
            let cached = CachedTransitData(payload: payload, arrivals: results, fetchedAt: fetchedAt, context: context)
            self.latest = cached // Cache before any BLE transfer, including while disconnected.
            FileLogger.shared.log("[CACHE] Transit API refresh complete; cache updated bytes=\(payload.count)")
            return cached
        }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        do { return try await task.value }
        catch {
            FileLogger.shared.log("[CACHE] Transit API refresh failed; cache not replaced code=\((error as NSError).code)")
            throw error
        }
    }
}
