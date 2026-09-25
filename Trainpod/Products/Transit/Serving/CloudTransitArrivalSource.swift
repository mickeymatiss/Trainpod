import CoreLocation
import Foundation

/// One cloud implementation for every normalized system, including station selection.
@MainActor
final class CloudTransitArrivalSource: TransitArrivalSource {
    private var services: [TransitSystemID: RealtimeTransitService] = [:]
    private var inFlight: [TransitSystemID: Task<Void, Never>] = [:]

    func lastSnapshot(for system: TransitSystemID) -> TransitRealtimeSnapshot? { services[system]?.snapshot }

    func arrivals(for context: TransitQueryContext, manifest: TransitSystemManifest?) async throws -> TransitArrivalResult {
        guard let manifest, manifest.systemId == context.systemId.rawValue else { throw CloudServingError.manifestUnavailable }
        let service = services[context.systemId] ?? RealtimeTransitService()
        services[context.systemId] = service
        // Short in-memory reuse never changes the source timestamp used for freshness.
        let age = service.fetchedAt.map { Date().timeIntervalSince($0) } ?? .infinity
        if age < 0 || age > 20 || service.snapshot == nil || service.lastError != nil {
            if let task = inFlight[context.systemId] { await task.value }
            else {
                let task = Task { await service.refresh(systemId: context.systemId) }
                inFlight[context.systemId] = task
                await task.value
                inFlight[context.systemId] = nil
            }
        }
        try Task.checkCancellation()
        if let error = service.lastError { throw CloudServingError.unavailable(error) }
        guard let snapshot = service.snapshot else { throw CloudServingError.noStations }
        guard snapshot.sourceAge() < 180 else { throw CloudServingError.stale }
        let selected = TransitStationSelection.select(context, manifest: manifest)
        guard !selected.isEmpty else { throw CloudServingError.noStations }
        let selectedIDs = Set(selected.map(\.id))
        let scoped = TransitRealtimeSnapshot(schemaVersion: snapshot.schemaVersion, systemId: snapshot.systemId,
            generatedAt: snapshot.generatedAt, sourceTimestamp: snapshot.sourceTimestamp,
            stations: snapshot.stations.filter { selectedIDs.contains($0.key) })
        let resolved = try await Task.detached(priority: .userInitiated) {
            try RealtimeResolver.resolve(snapshot: scoped, manifest: manifest)
        }.value
        guard resolved.diagnostics["unknown_station"] == nil,
              resolved.diagnostics["unknown_platform"] == nil,
              resolved.diagnostics["unknown_route"] == nil else { throw CloudServingError.unusableReferences }
        // CTA's cloud manifest can omit directions. Use the same stop metadata
        // as the legacy CTA source, keeping platform IDs only for grouping.
        var ctaDirectionLabels: [String: String] = [:]
        if context.systemId == .cta {
            let metadata = try await CTAStationRepository().loadStations()
            for station in selected {
                let stopDirections = metadata.first { $0.mapID == station.id }?.stopDirections
                for platform in station.platforms.values where snapshot.stations[station.id]?.platforms[platform.id] != nil {
                    guard let direction = stopDirections?[platform.id] else {
                        // Let the existing legacy fallback handle unresolved CTA data.
                        throw CloudServingError.unusableReferences
                    }
                    ctaDirectionLabels[platform.id] = LiveTransitFormatter.directionLabel(direction)
                }
            }
        }
        let location = CLLocation(latitude: context.latitude, longitude: context.longitude)
        let now = Date()
        let boards = selected.compactMap { station -> StationArrivals? in
            guard let realtime = snapshot.stations[station.id] else { return nil }
            let platforms = station.platforms.values.sorted { $0.id < $1.id }.compactMap { platform -> DirectionArrivals? in
                guard realtime.platforms[platform.id] != nil else { return nil }
                let predictions = resolved.arrivals.filter { $0.stationId == station.id && $0.platformId == platform.id && $0.arrivalAt >= now }
                let destinations = Set(predictions.compactMap(\.destinationName))
                let label = ctaDirectionLabels[platform.id] ?? platform.direction.map(LiveTransitFormatter.directionLabel)
                    ?? (destinations.count == 1 ? "To " + destinations.first! : "Platform " + platform.id)
                let trains = predictions.map { arrival in
                    CTAArrival(id: arrival.tripId, route: arrival.routeId,
                        destination: arrival.destinationName ?? "Destination unavailable", arrivalTime: arrival.arrivalAt,
                        approaching: arrival.arrivalAt.timeIntervalSince(now) < 60, delayed: false,
                        stationName: station.name, stopDescription: label, directionID: platform.id,
                        routeDisplayName: arrival.routeName, routeDisplayColor: arrival.routeColor)
                }
                return DirectionArrivals(id: platform.id, name: label, trains: trains)
            }
            guard !platforms.isEmpty else { return nil }
            return StationArrivals(station: TransitStationSelection.legacyStation(station, system: context.systemId),
                directions: platforms, distanceMeters: CLLocation(latitude: station.latitude, longitude: station.longitude).distance(from: location))
        }
        // BART's Airport Connector is static-only. A nearby live station can still serve.
        guard (!context.systemId.supportsLegacySource ? !boards.isEmpty : boards.count == selected.count), boards.contains(where: { $0.directions.contains { !$0.trains.isEmpty } }) else {
            throw CloudServingError.noStations
        }
        var query = context
        query.stationIds = boards.map { $0.station.mapID }
        return TransitArrivalResult(context: query, stations: boards, completedAt: service.fetchedAt ?? Date(),
            source: .cloud, manifest: manifest, snapshot: snapshot, cloudError: nil)
    }
}
