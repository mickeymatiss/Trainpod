import CoreLocation
import Foundation

@MainActor
protocol TransitLocationProvider {
    func currentLocation(system: TransitSystemID) async throws -> CLLocation
}

@MainActor
final class RealTransitLocationProvider: TransitLocationProvider {
    private let service = LocationService()
    func enableBackgroundLocation() { service.enableBackgroundLocation() }
    func currentLocation(system: TransitSystemID) async throws -> CLLocation {
        if let recent = service.recentLocation { return recent }
        return try await service.requestCurrentLocation()
    }
}

/// The only runtime boundary that knows whether a debug location override is active.
@MainActor
final class TransitLocationSource: TransitLocationProvider {
    static let shared = TransitLocationSource()
    private let real = RealTransitLocationProvider()
    var revision: String {
        #if DEBUG
        return TransitLocationSimulator.shared.revision.uuidString + MTALocationMode.selected.rawValue
        #else
        return "real"
        #endif
    }
    var label: String {
        #if DEBUG
        if TransitLocationSimulator.shared.coordinate != nil,
           TransitLocationSimulator.shared.system == TransitAgency.selected.systemID { return "Simulated location" }
        if TransitAgency.selected == .mta && MTALocationMode.selected != .current { return "Existing MTA test location" }
        #endif
        return "Real location"
    }
    func enableBackgroundLocation() { real.enableBackgroundLocation() }
    func currentLocation(system: TransitSystemID) async throws -> CLLocation {
        #if DEBUG
        if let fix = try TransitLocationSimulator.shared.location(for: system) { return fix }
        if system == .nyc, let fix = MTALocationMode.selected.locationOverride { return fix }
        #endif
        return try await real.currentLocation(system: system)
    }
}
