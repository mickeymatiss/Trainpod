import CoreLocation
import Foundation
import Combine

enum LiveTransitError: LocalizedError {
    case noDirections, payloadTooLarge
    var errorDescription: String? {
        switch self {
        case .noDirections: return "No valid station data is currently available."
        case .payloadTooLarge: return "Live transit payload exceeds the device limit."
        }
    }
}

@MainActor
protocol TransitPayloadProvider {
    func currentPayload() async throws -> Data
}

/// Resolve the current station context; share fresh API data with the foreground UI.
@MainActor
final class LiveTransitProvider: ObservableObject, TransitPayloadProvider {
    private let location = LocationService()
    private let stations = CTAStationRepository()
    private let cache = TransitDataCache.shared
    private var inFlight: Task<Data, Error>?

    func enableBackgroundLocation() { location.enableBackgroundLocation() }

    func currentPayload() async throws -> Data {
        if let inFlight {
            FileLogger.shared.log("[CACHE] Context/API refresh already in progress; coalescing request")
            return try await inFlight.value
        }
        let task = Task { @MainActor in
            let known = [self.location.recentLocation, self.cache.recentLocation]
                .compactMap { $0 }.max { $0.timestamp < $1.timestamp }
            let fix: CLLocation
            if let known { fix = known }
            else {
                FileLogger.shared.log("[CACHE] Resolving current station context")
                fix = try await self.location.requestCurrentLocation()
            }
            self.cache.rememberLocation(fix)
            let metadata = try await self.stations.loadStations()
            let nearest = Array(metadata.sorted {
                $0.location.distance(from: fix) < $1.location.distance(from: fix)
            }.prefix(2))
            return try await self.cache.result(for: nearest).payload
        }
        inFlight = task
        defer { inFlight = nil }
        // Cancelling a BLE waiter must not discard useful in-flight API results.
        return try await task.value
    }
}
