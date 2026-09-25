import Combine
import CoreLocation
import Foundation

/// Existing payload-provider contract, backed by cloud serving and direct-source fallback.
@MainActor
final class LiveTransitProvider: ObservableObject, TransitPayloadProvider {
    private var inFlight: (id: UUID, key: String, task: Task<TransitArrivalResult, Error>)?
    func enableBackgroundLocation() { TransitLocationSource.shared.enableBackgroundLocation() }

    func currentArrivals() async throws -> TransitArrivalResult {
        let system = TransitAgency.selected.systemID
        let revision = TransitLocationSource.shared.revision
        let key = system.rawValue + revision
        if let inFlight, inFlight.key == key {
            let result = try await inFlight.task.value
            try Task.checkCancellation()
            guard TransitAgency.selected.systemID == system, TransitLocationSource.shared.revision == revision else {
                throw CancellationError()
            }
            return result
        }
        let id = UUID()
        let task = Task {
            let location = try await TransitLocationSource.shared.currentLocation(system: system)
            try Task.checkCancellation()
            let query = TransitQueryContext(systemId: system, latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude, locationLabel: TransitLocationSource.shared.label)
            let result = try await TransitServingCoordinator.shared.serve(query)
            guard TransitAgency.selected.systemID == system, TransitLocationSource.shared.revision == revision else {
                throw CancellationError()
            }
            return result
        }
        inFlight = (id, key, task)
        defer { if inFlight?.id == id { inFlight = nil } }
        return try await task.value
    }

    func currentPayload() async throws -> Data {
        let result = try await currentArrivals()
        guard let payload = result.payload else { throw LiveTransitError.noDirections }
        return payload
    }
}
