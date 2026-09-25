#if DEBUG
import Combine
import CoreLocation
import Foundation

/// Port of TransitHelpers/dist/geo.js. Session-only overrides; never saved as GPS fixes.
@MainActor
final class TransitLocationSimulator: ObservableObject {
    static let shared = TransitLocationSimulator()
    @Published private(set) var coordinate: CLLocationCoordinate2D?
    @Published private(set) var system: TransitSystemID?
    @Published private(set) var revision = UUID()
    @Published var squareMiles = 4

    func useRealLocation() {
        coordinate = nil; system = nil; revision = UUID()
        UserDefaults.standard.set(MTALocationMode.current.rawValue, forKey: MTALocationMode.preferenceKey)
    }

    func generate(system: TransitSystemID) {
        // Same centers, square sizes, miles-per-degree conversion and rounding as the desktop helper.
        let center: (lat: Double, lon: Double)
        switch system {
        case .cta: center = (41.900, -87.655)
        case .nyc: center = (40.745, -73.977)
        case .bart: center = (37.789, -122.401) // Downtown San Francisco BART corridor.
        case .mbta: center = (42.356, -71.062) // Downtown Boston near Park Street.
        }
        let miles = [2, 4, 6].contains(squareMiles) ? Double(squareMiles) : 4
        let dy = miles / 2 / 69.093
        let dx = dy / cos(center.lat * .pi / 180)
        let latitude = Double.random(in: (center.lat - dy)...(center.lat + dy))
        let longitude = Double.random(in: (center.lon - dx)...(center.lon + dx))
        coordinate = CLLocationCoordinate2D(latitude: (latitude * 1e6).rounded() / 1e6,
                                            longitude: (longitude * 1e6).rounded() / 1e6)
        self.system = system
        revision = UUID()
        UserDefaults.standard.set(system.agency.rawValue,
                                  forKey: TransitAgency.preferenceKey)
        UserDefaults.standard.set(MTALocationMode.current.rawValue, forKey: MTALocationMode.preferenceKey)
        FileLogger.shared.log("[TRANSIT] dev_location_simulated systemId=\(system.rawValue)")
    }

    func location(for system: TransitSystemID) throws -> CLLocation? {
        guard self.system == system, let coordinate else { return nil }
        return CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
    }
}
#endif
