import Foundation

nonisolated struct TransitRealtimeSnapshot: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let systemId: String
    let generatedAt: Int64
    let sourceTimestamp: Int64
    let stations: [String: TransitRealtimeStation]

    func sourceAge(at now: Date = Date()) -> TimeInterval {
        now.timeIntervalSince1970 - Double(sourceTimestamp)
    }
    func generatedAge(at now: Date = Date()) -> TimeInterval {
        now.timeIntervalSince1970 - Double(generatedAt)
    }
}

nonisolated struct TransitRealtimeStation: Codable, Equatable, Sendable {
    let platforms: [String: TransitRealtimePlatform]
}

nonisolated struct TransitRealtimePlatform: Codable, Equatable, Sendable {
    let arrivals: [TransitArrival]
}

nonisolated struct TransitArrival: Codable, Equatable, Sendable {
    let routeId: String
    let tripId: String
    let arrivalAt: Int64
    let destinationStationId: String?
}
