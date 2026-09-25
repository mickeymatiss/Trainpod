import CoreLocation
import Foundation

/// Calls unmodified direct-provider clients; its cache is separate from the serving cloud cache.
@MainActor
final class LegacyTransitArrivalSource: TransitArrivalSource {
    private let mta = MTAClient()

    func arrivals(for context: TransitQueryContext, manifest: TransitSystemManifest?) async throws -> TransitArrivalResult {
        guard context.systemId.supportsLegacySource else { throw LegacyTransitUnavailable(system: context.systemId) }
        let fix = CLLocation(latitude: context.latitude, longitude: context.longitude)
        let canonical = manifest.map { TransitStationSelection.select(context, manifest: $0) } ?? []
        let stations: [CTAStation]
        if context.systemId == .cta {
            let metadata = try await CTAStationRepository().loadStations()
            if !canonical.isEmpty {
                stations = canonical.map { station in
                    metadata.first { $0.mapID == station.id }
                        ?? TransitStationSelection.legacyStation(station, system: context.systemId)
                }
            } else {
                stations = Array(metadata.filter(\.isRealtimeCandidate).sorted {
                    let a = $0.location.distance(from: fix), b = $1.location.distance(from: fix)
                    return a == b ? $0.mapID < $1.mapID : a < b
                }.prefix(LiveTransitFormatter.maximumStations))
            }
        } else if !canonical.isEmpty {
            stations = canonical.map { TransitStationSelection.legacyStation($0, system: context.systemId) }
        } else {
            stations = try await MTAStationRepository.shared.nearest(to: fix).map(\.station)
        }
        guard !stations.isEmpty else { throw LiveTransitError.noDirections }
        let output: [StationArrivals]
        if context.systemId == .nyc {
            output = try await mta.arrivals(for: stations.map { StationArrivals(station: $0, directions: [], distanceMeters: $0.location.distance(from: fix)) }, maxAge: 0)
        } else {
            // A maximum of two direct calls; no retries, scan, or quota-expanding loop.
            output = try await withThrowingTaskGroup(of: (Int, StationArrivals).self) { group in
                for (index, station) in stations.enumerated() {
                    group.addTask { @MainActor in
                        let trains = try await CTAClient().fetchArrivals(for: station, maxArrivals: 60, timeout: 5)
                        var board = NearbyStationsViewModel.groupArrivals(trains, for: station)
                        board.distanceMeters = station.location.distance(from: fix)
                        return (index, board)
                    }
                }
                var results: [(Int, StationArrivals)] = []
                for try await result in group { results.append(result) }
                return results.sorted { $0.0 < $1.0 }.map { $0.1 }
            }
        }
        return TransitArrivalResult(context: context, stations: output, completedAt: Date(), source: .legacyFallback,
            manifest: manifest, snapshot: nil, cloudError: nil)
    }
}
