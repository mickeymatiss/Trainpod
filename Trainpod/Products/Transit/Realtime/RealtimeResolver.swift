import Foundation

nonisolated struct ResolvedTransitArrival: Sendable {
    let systemId: TransitSystemID
    let stationId: String
    let stationName: String
    let platformId: String
    let direction: String?
    let routeId: String
    let routeName: String
    let routeColor: String?
    let tripId: String
    let arrivalAt: Date
    let destinationStationId: String?
    let destinationName: String?
}

nonisolated struct RealtimeResolution: Sendable {
    var arrivals: [ResolvedTransitArrival] = []
    var diagnostics: [String: Int] = [:]
    mutating func count(_ kind: String, by count: Int = 1) { diagnostics[kind, default: 0] += count }
}

nonisolated enum RealtimeResolver {
    static func validate(_ snapshot: TransitRealtimeSnapshot, systemId: TransitSystemID, now: Date = Date()) throws {
        guard snapshot.schemaVersion == 1 else { throw RealtimeTransitError.invalidSnapshot("unsupported schema") }
        guard snapshot.systemId == systemId.rawValue else { throw RealtimeTransitError.invalidSnapshot("system mismatch") }
        let upper = now.timeIntervalSince1970 + 60
        // Old data remains inspectable. Future/invalid timestamps cannot masquerade as fresh.
        guard snapshot.generatedAt >= 946684800, snapshot.sourceTimestamp >= 946684800,
              Double(snapshot.generatedAt) <= upper, Double(snapshot.sourceTimestamp) <= upper,
              Double(snapshot.sourceTimestamp) <= Double(snapshot.generatedAt) + 60 else {
            throw RealtimeTransitError.invalidSnapshot("unreasonable timestamps")
        }
    }

    static func resolve(snapshot: TransitRealtimeSnapshot, manifest: TransitSystemManifest) throws -> RealtimeResolution {
        guard let system = TransitSystemID(rawValue: snapshot.systemId), manifest.systemId == snapshot.systemId else {
            throw RealtimeTransitError.invalidSnapshot("manifest system mismatch")
        }
        var result = RealtimeResolution()
        for (sid, station) in snapshot.stations.sorted(by: { $0.key < $1.key }) {
            guard let metadata = manifest.stations[sid] else { result.count("unknown_station"); continue }
            for (pid, platform) in station.platforms.sorted(by: { $0.key < $1.key }) {
                guard let platformMetadata = metadata.platforms[pid] else { result.count("unknown_platform"); continue }
                for arrival in platform.arrivals {
                    guard let route = manifest.routes[arrival.routeId] else { result.count("unknown_route"); continue }
                    guard !arrival.tripId.isEmpty, arrival.arrivalAt >= 946684800,
                          Double(arrival.arrivalAt) <= Double(snapshot.generatedAt) + 86400 else {
                        result.count("invalid_arrival"); continue
                    }
                    let destination = arrival.destinationStationId.flatMap { manifest.stations[$0] }
                    if arrival.destinationStationId != nil && destination == nil { result.count("unknown_destination") }
                    result.arrivals.append(ResolvedTransitArrival(systemId: system, stationId: sid,
                        stationName: metadata.name, platformId: pid, direction: platformMetadata.direction,
                        routeId: arrival.routeId, routeName: route.name, routeColor: route.color,
                        tripId: arrival.tripId, arrivalAt: Date(timeIntervalSince1970: Double(arrival.arrivalAt)),
                        destinationStationId: arrival.destinationStationId, destinationName: destination?.name))
                }
            }
        }
        result.arrivals.sort { $0.arrivalAt < $1.arrivalAt }
        return result
    }
}
