import Foundation

/// Static manifest v1. These fields mirror the server contract, without UI state.
nonisolated struct TransitSystemManifest: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let systemId: String
    let generatedAt: String
    let sourceVersion: String?
    let routes: [String: TransitRoute]
    let stations: [String: TransitStation]
}

nonisolated struct TransitRoute: Codable, Equatable, Sendable {
    let id: String
    let name: String
    let color: String?
    let textColor: String?
}

nonisolated struct TransitStation: Codable, Equatable, Sendable {
    let id: String
    let name: String
    let latitude: Double
    let longitude: Double
    let platforms: [String: TransitPlatform]
}

nonisolated struct TransitPlatform: Codable, Equatable, Sendable {
    let id: String
    let direction: String?
    let routeIds: [String]
}
