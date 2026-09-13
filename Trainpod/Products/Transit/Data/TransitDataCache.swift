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

    func rememberLocation(_ fix: CLLocation) { lastLocation = fix }

    var recentLocation: CLLocation? {
        guard let fix = lastLocation, fix.horizontalAccuracy >= 0,
              fix.horizontalAccuracy <= 1000,
              (0..<Self.freshnessInterval).contains(-fix.timestamp.timeIntervalSinceNow) else { return nil }
        return fix
    }

    private func withCurrentDistances(_ arrivals: [StationArrivals]) -> [StationArrivals] {
        // Opportunistic only: reuse a fix obtained by normal transit/location
        // work. Never request a fix or start a timer for the distance label.
        let fix = recentLocation
        return arrivals.map { original in
            var station = original
            station.distanceMeters = fix.map { station.station.location.distance(from: $0) }
                ?? original.distanceMeters
                ?? latest?.arrivals.first(where: { $0.station.id == original.station.id })?.distanceMeters
            return station
        }
    }

    func result(for stations: [CTAStation]) async throws -> CachedTransitData {
        // A station can appear only once, even if metadata contains duplicate rows.
        var seen = Set<String>()
        let candidates = stations.filter { $0.isRealtimeCandidate && seen.insert($0.mapID).inserted }
        // Ordered IDs preserve the nearest-station preference and isolate agency/context.
        let context = ["CTA", "TP2-platform-pages-\(LiveTransitFormatter.maximumPlatforms)"] + candidates.map(\.mapID)
        let key = context.joined(separator: ":")
        if let cached = latest {
            let age = Date().timeIntervalSince(cached.fetchedAt)
            FileLogger.shared.log("[CACHE] age=\(Int(age))s contextMatches=\(cached.context == context)")
            if cached.context == context, age >= 0, age < Self.freshnessInterval {
                PhoneDiagnosticLog.shared.record("PAYLOAD_CACHE_HIT", value1: Int64(cached.payload.count))
                FileLogger.shared.log("[CACHE] Serving cached transit data")
                let arrivals = withCurrentDistances(cached.arrivals)
                let refreshed = CachedTransitData(payload: try LiveTransitFormatter.payload(from: arrivals),
                    arrivals: arrivals, fetchedAt: cached.fetchedAt, context: context)
                latest = refreshed
                return refreshed
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
            // Backfill failed stations without letting an agency outage scan
            // the entire system or exhaust the existing BLE request deadline.
            let selectionDeadline = Date().addingTimeInterval(15)
            var results: [StationArrivals] = []
            // Fetch distance-ordered pairs concurrently. A five-second failure
            // cannot prevent its partner from succeeding; pairs 1/2 then 3/4
            // still select 2/4 if 1 and 3 fail. Append in distance order, never
            // completion order, and count only successful station results.
            for index in stride(from: 0, to: candidates.count, by: 2) {
                if results.count == LiveTransitFormatter.maximumStations { break }
                try Task.checkCancellation()
                if Date() >= selectionDeadline { break }
                let next = index + 1 < candidates.count ? candidates[index + 1] : nil
                async let first = self.fetchCandidate(candidates[index], before: selectionDeadline)
                async let second = self.fetchCandidate(next, before: selectionDeadline)
                let pair = try await (first, second)
                for station in [pair.0, pair.1].compactMap({ $0 }) {
                    guard results.count < LiveTransitFormatter.maximumStations else { break }
                    results.append(station)
                    FileLogger.shared.log("[TRANSIT] Selected station \(results.count): \(station.station.name)")
                }
            }
            let diagnosticSession = PhoneDiagnosticLog.shared.currentSessionId
            PhoneDiagnosticLog.shared.record("PAYLOAD_BUILD_STARTED", sessionId: diagnosticSession)
            results = self.withCurrentDistances(results)
            let payload: Data
            do {
                payload = try LiveTransitFormatter.payload(from: results)
                PhoneDiagnosticLog.shared.record("PAYLOAD_BUILD_COMPLETE", sessionId: diagnosticSession, value1: Int64(payload.count))
            } catch {
                PhoneDiagnosticLog.shared.record("PAYLOAD_BUILD_FAILED", sessionId: diagnosticSession, level: "ERROR", value1: Int64((error as NSError).code))
                throw error
            }
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

    private func fetchCandidate(_ station: CTAStation?, before deadline: Date) async throws -> StationArrivals? {
        guard let station else { return nil }
        try Task.checkCancellation()
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else { return nil }
        do {
            let trains = try await CTAClient().fetchArrivals(for: station, maxArrivals: 60, timeout: min(5, remaining))
            try Task.checkCancellation()
            let grouped = NearbyStationsViewModel.groupArrivals(trains, for: station)
            guard !grouped.directions.isEmpty else {
                FileLogger.shared.log("[TRANSIT] Skipped station \(station.mapID): no usable platforms")
                return nil
            }
            // A successful API response with empty arrivals is still valid:
            // absence of a train prediction does not itself mean a station is down.
            return grouped
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            FileLogger.shared.log("[TRANSIT] Skipped failed station \(station.mapID) code=\((error as NSError).code)")
            return nil
        }
    }

}
