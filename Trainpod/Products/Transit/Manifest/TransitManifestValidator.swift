import Foundation

nonisolated enum TransitManifestError: LocalizedError {
    case configuration, invalidResponse, httpStatus(Int), invalidManifest(String), missingCache

    var errorDescription: String? {
        switch self {
        case .configuration: return "The transit manifest server URL has not been configured."
        case .invalidResponse: return "The transit manifest server returned an invalid response."
        case .httpStatus(let status): return "The transit manifest request failed (HTTP \(status))."
        case .invalidManifest(let reason): return "Invalid transit manifest: \(reason)."
        case .missingCache: return "The manifest server returned unchanged data without a local copy."
        }
    }
}

nonisolated enum TransitManifestValidator {
    static func validate(_ manifest: TransitSystemManifest, expectedSystemID: TransitSystemID) throws {
        func require(_ condition: Bool, _ reason: String) throws {
            guard condition else { throw TransitManifestError.invalidManifest(reason) }
        }
        func validID(_ value: String) -> Bool {
            !value.isEmpty && !value.contains(where: \.isWhitespace)
        }
        func validColor(_ value: String?) -> Bool {
            guard let value else { return true }
            return value.count == 7 && value.first == "#"
                && value.dropFirst().allSatisfy { $0.isASCII && $0.isHexDigit }
        }
        try require(manifest.schemaVersion == 1, "unsupported schema version")
        try require(manifest.systemId == expectedSystemID.rawValue, "system mismatch")
        try require(!manifest.routes.isEmpty && !manifest.stations.isEmpty, "empty routes or stations")
        let timestamp = ISO8601DateFormatter()
        let plainDate = timestamp.date(from: manifest.generatedAt)
        timestamp.formatOptions.insert(.withFractionalSeconds)
        try require(plainDate != nil || timestamp.date(from: manifest.generatedAt) != nil, "invalid generatedAt")
        for (id, route) in manifest.routes {
            try require(validID(id) && id == route.id, "route ID mismatch")
            try require(!route.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "empty route name")
            try require(validColor(route.color) && validColor(route.textColor), "invalid route color")
        }
        var platformIDs = Set<String>()
        for (id, station) in manifest.stations {
            try require(validID(id) && id == station.id, "station ID mismatch")
            try require(!station.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "empty station name")
            try require(station.latitude.isFinite && (-90...90).contains(station.latitude)
                && station.longitude.isFinite && (-180...180).contains(station.longitude), "invalid coordinates")
            try require(!station.platforms.isEmpty, "empty station platforms")
            for (platformID, platform) in station.platforms {
                try require(validID(platformID) && platformID == platform.id, "platform ID mismatch")
                try require(platformIDs.insert(platformID).inserted, "platform belongs to multiple stations")
                try require(Set(platform.routeIds).count == platform.routeIds.count, "duplicate route reference")
                try require(platform.routeIds.allSatisfy { manifest.routes[$0] != nil }, "unknown platform route")
            }
        }
    }
}
