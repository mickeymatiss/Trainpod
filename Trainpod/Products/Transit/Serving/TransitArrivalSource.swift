import CoreLocation
import Foundation

nonisolated struct TransitQueryContext: Sendable {
    let systemId: TransitSystemID
    let latitude: Double
    let longitude: Double
    var stationIds: [String] = []
    var locationLabel: String = "Real location"
}

nonisolated enum TransitServingSource: String, Sendable { case cloud, legacyFallback }

struct TransitArrivalResult {
    let id = UUID()
    var payload: Data? = nil
    let context: TransitQueryContext
    let stations: [StationArrivals]
    let completedAt: Date
    let source: TransitServingSource
    let manifest: TransitSystemManifest?
    let snapshot: TransitRealtimeSnapshot?
    let cloudError: String?
}

@MainActor
protocol TransitArrivalSource {
    func arrivals(for context: TransitQueryContext, manifest: TransitSystemManifest?) async throws -> TransitArrivalResult
}

nonisolated enum CloudServingError: LocalizedError, Equatable {
    case manifestUnavailable, stale, unavailable(String), noStations, unusableReferences
    var errorDescription: String? {
        switch self {
        case .manifestUnavailable: return "The system manifest is not cached yet."
        case .stale: return "Cloud arrivals are at least 180 seconds old."
        case .unavailable(let message): return message
        case .noStations: return "No usable cloud station arrivals are available."
        case .unusableReferences: return "Cloud arrivals contain unresolved static references."
        }
    }
}

@MainActor
enum TransitStationSelection {
    static func select(_ context: TransitQueryContext, manifest: TransitSystemManifest) -> [TransitStation] {
        if !context.stationIds.isEmpty { return context.stationIds.compactMap { manifest.stations[$0] } }
        let location = CLLocation(latitude: context.latitude, longitude: context.longitude)
        return Array(manifest.stations.values.sorted {
            let a = CLLocation(latitude: $0.latitude, longitude: $0.longitude).distance(from: location)
            let b = CLLocation(latitude: $1.latitude, longitude: $1.longitude).distance(from: location)
            return a == b ? $0.id < $1.id : a < b
        }.prefix(LiveTransitFormatter.maximumStations))
    }

    static func legacyStation(_ station: TransitStation, system: TransitSystemID) -> CTAStation {
        CTAStation(id: system == .nyc ? "MTA-" + station.id : system == .cta ? station.id : system.rawValue.uppercased() + "-" + station.id,
            name: station.name, latitude: station.latitude, longitude: station.longitude,
            mapID: station.id, stopIDs: station.platforms.keys.sorted(),
            stopDirections: Dictionary(uniqueKeysWithValues: station.platforms.values.compactMap {
                guard let direction = $0.direction else { return nil }
                return ($0.id, direction)
            }))
    }
}

nonisolated struct TransitServingFailure: LocalizedError {
    let cloudError: String
    let legacyError: String
    var errorDescription: String? { "Cloud unavailable (\(cloudError)); direct fallback failed (\(legacyError))." }
}

nonisolated struct LegacyTransitUnavailable: LocalizedError {
    let system: TransitSystemID
    var errorDescription: String? { "\(system.rawValue.uppercased()) uses cloud arrivals; no direct fallback is available." }
}
