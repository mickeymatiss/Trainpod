import CoreLocation
import Foundation
import Combine

enum LiveTransitError: LocalizedError {
    case noDirections, payloadTooLarge, platformCapacityExceeded
    var errorDescription: String? {
        switch self {
        case .noDirections: return "No valid station data is currently available."
        case .platformCapacityExceeded: return "More platform directions than the device supports. View all directions in the app."
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
            let agency = TransitAgency.selected
            let mtaLocationMode = MTALocationMode.selected
            let payload = try await inFlight.value
            guard TransitAgency.selected == agency,
                  agency != .mta || MTALocationMode.selected == mtaLocationMode else { throw CancellationError() }
            return payload
        }
        let agency = TransitAgency.selected
        let mtaLocationMode = MTALocationMode.selected
        let task = Task { @MainActor in
            let known = [self.location.recentLocation, self.cache.recentLocation]
                .compactMap { $0 }.max { $0.timestamp < $1.timestamp }
            let fix: CLLocation
            let diagnosticSession = PhoneDiagnosticLog.shared.currentSessionId
            if agency == .mta, let testLocation = mtaLocationMode.locationOverride {
                fix = testLocation
                FileLogger.shared.log("[MTA] Using \(mtaLocationMode.rawValue) test location")
            } else if let known {
                fix = known
                PhoneDiagnosticLog.shared.record("LOCATION_CACHED", sessionId: diagnosticSession)
            }
            else {
                FileLogger.shared.log("[CACHE] Resolving current station context")
                PhoneDiagnosticLog.shared.record("LOCATION_REQUEST_STARTED", sessionId: diagnosticSession)
                do {
                    fix = try await self.location.requestCurrentLocation()
                    PhoneDiagnosticLog.shared.record("LOCATION_SUCCESS", sessionId: diagnosticSession)
                } catch {
                    PhoneDiagnosticLog.shared.record("LOCATION_FAILURE", sessionId: diagnosticSession, level: "ERROR", value1: Int64((error as NSError).code))
                    throw error
                }
            }
            if agency != .mta || mtaLocationMode == .current {
                self.cache.rememberLocation(fix)
            }
            PhoneDiagnosticLog.shared.record("STATION_RESOLUTION_STARTED", sessionId: diagnosticSession)
            if agency == .mta {
                let stations = try await MTAStationRepository.shared.nearest(to: fix)
                let nearby = try await MTAClient.shared.arrivals(for: stations)
                guard TransitAgency.selected == agency,
                  agency != .mta || MTALocationMode.selected == mtaLocationMode else { throw CancellationError() }
                return try LiveTransitFormatter.payload(from: nearby)
            }
            let metadata: [CTAStation]
            do { metadata = try await self.stations.loadStations() }
            catch {
                PhoneDiagnosticLog.shared.record("STATION_RESOLUTION_FAILURE", sessionId: diagnosticSession, level: "ERROR", value1: Int64((error as NSError).code))
                throw error
            }
            // Keep distance-ordered fallback candidates: a failed/closed station
            // must not consume one of the two successful station slots.
            let nearest = metadata.filter(\.isRealtimeCandidate).sorted {
                let left = $0.location.distance(from: fix), right = $1.location.distance(from: fix)
                return left == right ? $0.mapID < $1.mapID : left < right
            }
            PhoneDiagnosticLog.shared.record("STATION_RESOLUTION_SUCCESS", sessionId: diagnosticSession, value1: Int64(nearest.count))
            let payload = try await self.cache.result(for: nearest).payload
            guard TransitAgency.selected == agency,
                  agency != .mta || MTALocationMode.selected == mtaLocationMode else { throw CancellationError() }
            return payload
        }
        inFlight = task
        defer { inFlight = nil }
        // Cancelling a BLE waiter must not discard useful in-flight API results.
        let payload = try await task.value
        guard TransitAgency.selected == agency,
                  agency != .mta || MTALocationMode.selected == mtaLocationMode else { throw CancellationError() }
        return payload
    }
}
