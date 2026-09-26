import Foundation
import CoreLocation

@main struct Smoke {
    @MainActor static func main() async throws {
        // Public test coordinate at Times Square, independent of the user's location.
        let stations = try await MTAStationRepository.shared.nearest(to: MTALocationMode.timesSquare.locationOverride!)
        let result = try await MTAClient.shared.arrivals(for: stations)
        assert(result.count == 2 && result[0].station.mapID == "611")
        for station in result {
            let trains = station.directions.flatMap(\.trains)
            assert(trains.count <= 9)
            print(station.station.name)
            for platform in station.directions {
                print("  Platform: \(platform.name)")
                for train in platform.trains { print("    \(train.route) \(Int(ceil(train.arrivalTime.timeIntervalSinceNow / 60))) min") }
            }
        }
    }
}
