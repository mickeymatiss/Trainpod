import CoreLocation
import Foundation

struct CTAStation: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let latitude: Double
    let longitude: Double
    let mapID: String
    let stopIDs: [String]
    var stopDirections: [String: String]? = nil

    var location: CLLocation {
        CLLocation(latitude: latitude, longitude: longitude)
    }

    var isRealtimeCandidate: Bool {
        guard let map = Int(mapID), map > 0, !stopIDs.isEmpty,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              CLLocationCoordinate2DIsValid(location.coordinate) else { return false }
        return !name.localizedCaseInsensitiveContains("closed")
    }
}

struct CTAArrival: Identifiable, Equatable, Sendable {
    let id: String
    let route: String
    let destination: String
    let arrivalTime: Date
    let approaching: Bool
    let delayed: Bool
    let stationName: String
    let stopDescription: String
    let directionID: String

    var directionName: String {
        stopDescription
            .replacingOccurrences(of: "Service toward ", with: "Toward ")
            .replacingOccurrences(of: "service toward ", with: "Toward ")
    }

    func status(relativeTo date: Date = Date()) -> String {
        if delayed {
            return "Delayed"
        }

        let secondsAway = max(0, Int(arrivalTime.timeIntervalSince(date)))
        if approaching || secondsAway < 60 {
            return "Due"
        }

        return "\(secondsAway / 60) min"
    }
}

struct StationArrivals: Identifiable, Equatable, Sendable {
    var id: String { station.id }

    let station: CTAStation
    let directions: [DirectionArrivals]
    var distanceMeters: Double? = nil
}

struct DirectionArrivals: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let trains: [CTAArrival]
}
