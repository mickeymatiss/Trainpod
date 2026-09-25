import Foundation

/// Only the comparison adapter understands identity lost by legacy provider DTOs.
@MainActor
enum LegacyArrivalAdapter {
    static func stationIDs(for station: CTAStation, system: TransitSystemID,
                           manifest: TransitSystemManifest) -> Set<String> {
        if system != .nyc { return manifest.stations[station.mapID] == nil ? [] : [station.mapID] }
        let stops = Set(station.stopIDs)
        return Set(manifest.stations.values.filter { item in
            stops.contains(item.id) || item.platforms.keys.contains(where: { stops.contains($0) })
        }.map(\.id))
    }

    static func arrivals(_ output: StationArrivals, system: TransitSystemID,
                         manifest: TransitSystemManifest?) -> [ComparableArrival] {
        let scope = manifest.map { stationIDs(for: output.station, system: system, manifest: $0) } ?? []
        return output.directions.flatMap(\.trains).enumerated().map { index, train in
            let route = manifest?.routes.keys.first { $0.caseInsensitiveCompare(train.route) == .orderedSame } ?? train.route
            var stationID: String?, platformID: String?, tripID: String?
            var note: String?
            if system == .cta {
                stationID = output.station.mapID
                let parts = train.id.split(separator: "-", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
                if parts.count == 4, parts[0] == output.station.mapID, output.station.stopIDs.contains(parts[1]) {
                    platformID = parts[1]; tripID = parts[2].isEmpty ? nil : parts[2]
                } else { note = "Legacy arrival ID lacks a reliable platform/run identity" }
            } else {
                tripID = train.id.isEmpty ? nil : train.id
                // Legacy NYC groups constituent GTFS stations into complexes. Recover
                // a platform only if static route+direction membership is unambiguous.
                let platforms = scope.sorted().flatMap { sid in
                    (manifest?.stations[sid]?.platforms.values.sorted { $0.id < $1.id } ?? []).compactMap { platform -> (String, String)? in
                        guard platform.direction == train.directionID, platform.routeIds.contains(route) else { return nil }
                        return (sid, platform.id)
                    }
                }
                let stations = Set(platforms.map { $0.0 })
                stationID = scope.count == 1 ? scope.first : stations.count == 1 ? stations.first : nil
                platformID = platforms.count == 1 ? platforms.first?.1 : nil
                if stationID == nil || platformID == nil { note = "Legacy station complex does not identify one canonical platform" }
            }
            let style = manifest?.routes[route]
            return ComparableArrival(id: "legacy-\(output.station.id)-\(index)", source: .legacy, stationId: stationID,
                platformId: platformID, direction: train.directionID, routeId: route, tripId: tripID,
                // NYC legacy destination is a direction label, not a terminal station.
                destination: system == .cta ? train.destination : nil, arrivalAt: train.arrivalTime,
                routeName: style?.name, routeColor: style?.color, identityNote: note)
        }
    }
}

/// Calls the existing clients for the station already chosen by the existing UI.
/// Private MTA instance avoids changing its production singleton's cached provider data.
@MainActor
final class LegacyComparisonSource {
    private let mta = MTAClient()
    func fetch(station: StationArrivals, system: TransitSystemID) async throws -> StationArrivals {
        switch system {
        case .cta:
            let trains = try await CTAClient().fetchArrivals(for: station.station, maxArrivals: 60, timeout: 10)
            return NearbyStationsViewModel.groupArrivals(trains, for: station.station)
        case .nyc:
            guard let output = try await mta.arrivals(for: [station], maxAge: 0).first else {
                throw RealtimeTransitError.invalidResponse
            }
            return output
        case .bart, .mbta:
            // These systems use cloud arrivals without a legacy iOS provider.
            throw LegacyTransitUnavailable(system: system)
        }
    }
}
