import CoreLocation
import Foundation

enum CTAStationRepositoryError: LocalizedError {
    case invalidURL
    case invalidResponse
    case noStations

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Could not build the CTA station metadata URL."
        case .invalidResponse: return "CTA station metadata returned an unexpected response."
        case .noStations: return "CTA station metadata did not include any valid rail stations."
        }
    }
}

struct CTAStationRepository {
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    func loadStations() async throws -> [CTAStation] {
        if let cachedStations = try loadCachedStations(), !cachedStations.isEmpty {
            return cachedStations
        }

        let stations = try await fetchStations()
        guard !stations.isEmpty else {
            throw CTAStationRepositoryError.noStations
        }

        try saveStations(stations)
        return stations
    }

    private func loadCachedStations() throws -> [CTAStation]? {
        let url = try cacheURL()
        guard fileManager.fileExists(atPath: url.path) else {
            return nil
        }

        let data = try Data(contentsOf: url)
        return try decoder.decode([CTAStation].self, from: data)
    }

    private func saveStations(_ stations: [CTAStation]) throws {
        let url = try cacheURL()
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let data = try encoder.encode(stations)
        try data.write(to: url, options: .atomic)
    }

    private func cacheURL() throws -> URL {
        let directory = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )

        return directory
            .appendingPathComponent("CTAStationMetadata", isDirectory: true)
            .appendingPathComponent("stations.json")
    }

    private func fetchStations() async throws -> [CTAStation] {
        guard var components = URLComponents(string: "https://data.cityofchicago.org/resource/8pix-ypme.json") else {
            throw CTAStationRepositoryError.invalidURL
        }

        components.queryItems = [
            URLQueryItem(name: "$limit", value: "5000")
        ]

        guard let url = components.url else {
            throw CTAStationRepositoryError.invalidURL
        }

        let (data, response) = try await URLSession.shared.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw CTAStationRepositoryError.invalidResponse
        }

        let stops = try decoder.decode([CTALStop].self, from: data)
        let groupedStops = Dictionary(grouping: stops) { $0.mapID }

        return groupedStops.compactMap { mapID, stops in
            guard let representative = stops.first,
                  let latitude = representative.location.latitudeValue,
                  let longitude = representative.location.longitudeValue else {
                return nil
            }

            return CTAStation(
                id: mapID,
                name: representative.stationName,
                latitude: latitude,
                longitude: longitude,
                mapID: mapID,
                stopIDs: stops.map(\.stopID).sorted()
            )
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

private struct CTALStop: Decodable {
    let stopID: String
    let stationName: String
    let mapID: String
    let location: CTALStopLocation

    enum CodingKeys: String, CodingKey {
        case stopID = "stop_id"
        case stationName = "station_name"
        case mapID = "map_id"
        case location
    }
}

private struct CTALStopLocation: Decodable {
    let latitude: String
    let longitude: String

    var latitudeValue: Double? { Double(latitude) }
    var longitudeValue: Double? { Double(longitude) }
}
