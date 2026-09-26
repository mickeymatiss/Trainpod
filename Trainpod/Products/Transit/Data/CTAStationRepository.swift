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
    private let session: URLSession

    init(fileManager: FileManager = .default, session: URLSession = .shared) {
        self.fileManager = fileManager
        self.session = session
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    func loadStations() async throws -> [CTAStation] {
        do {
            if let cachedStations = try loadCachedStations(), !cachedStations.isEmpty,
               cachedStations.allSatisfy({ $0.stopDirections != nil }) {
                return cachedStations
            }
        } catch {
            FileLogger.shared.log("[CACHE] CTA metadata cache unreadable; fetching metadata")
        }

        let stations = try await fetchStations()
        guard !stations.isEmpty else {
            throw CTAStationRepositoryError.noStations
        }

        do { try saveStations(stations) }
        catch { FileLogger.shared.log("[CACHE] CTA metadata save failed; using fetched metadata") }
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
        FileLogger.shared.log("[API] Station metadata request started")
        do {
        guard var components = URLComponents(string: "https://data.cityofchicago.org/resource/8pix-ypme.json") else {
            throw CTAStationRepositoryError.invalidURL
        }

        components.queryItems = [
            URLQueryItem(name: "$limit", value: "5000")
        ]

        guard let url = components.url else {
            throw CTAStationRepositoryError.invalidURL
        }

        let (data, response) = try await session.data(for: URLRequest(url: url, timeoutInterval: 6))
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            FileLogger.shared.log("[API] Invalid metadata response HTTP=\((response as? HTTPURLResponse)?.statusCode ?? 0)")
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
                stopIDs: stops.map(\.stopID).sorted(),
                stopDirections: Dictionary(stops.map { ($0.stopID, $0.directionID) }, uniquingKeysWith: { first, _ in first })
            )
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        } catch {
            FileLogger.shared.log("[API] Metadata request failed code=\((error as NSError).code) invalidData=\(error is DecodingError)")
            throw error
        }
    }
}

private struct CTALStop: Decodable {
    let stopID: String
    let directionID: String
    let stationName: String
    let mapID: String
    let location: CTALStopLocation

    enum CodingKeys: String, CodingKey {
        case stopID = "stop_id"
        case directionID = "direction_id"
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
