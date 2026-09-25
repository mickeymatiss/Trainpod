import CoreLocation
import Foundation

enum TransitAgency: String, CaseIterable, Identifiable {
    case cta = "CTA", mta = "MTA", bart = "BART", mbta = "MBTA"
    var id: String { rawValue }
    static let preferenceKey = "transitAgency"
    static var selected: Self {
        Self(rawValue: UserDefaults.standard.string(forKey: preferenceKey) ?? "CTA") ?? .cta
    }
}

/// Explicit MTA test context; never stored in the shared GPS cache used by CTA.
enum MTALocationMode: String, CaseIterable, Identifiable {
    case current = "Current Location"
    case timesSquare = "Times Square"
    case starrKnickerbocker = "Starr & Knickerbocker"
    var id: String { rawValue }
    static let preferenceKey = "mtaLocationMode"
    static var selected: Self {
        Self(rawValue: UserDefaults.standard.string(forKey: preferenceKey) ?? "") ?? .current
    }
    var locationOverride: CLLocation? {
        switch self {
        case .current: return nil
        case .timesSquare:
            // At the 42 St / Broadway station complex, rather than the plaza near 49 St.
            return CLLocation(latitude: 40.755746, longitude: -73.9875808)
        case .starrKnickerbocker:
            // Starr St & Knickerbocker Ave, Brooklyn 11237 (intersection geocode).
            return CLLocation(latitude: 40.702819, longitude: -73.925409)
        }
    }
}

/// Station metadata. Location stays on the phone; only the public catalog is downloaded.
@MainActor
final class MTAStationRepository {
    static let shared = MTAStationRepository()
    private var cached: [CTAStation]?

    private struct Row: Decodable {
        let complex_id: String
        let stop_name: String
        let latitude: String
        let longitude: String
        let gtfs_stop_ids: String
    }

    func nearest(to location: CLLocation) async throws -> [StationArrivals] {
        let stations = try await loadStations()
        try Task.checkCancellation()
        return Array(stations.sorted {
            let a = $0.location.distance(from: location), b = $1.location.distance(from: location)
            return a == b ? $0.id < $1.id : a < b
        }.prefix(2)).map {
            StationArrivals(station: $0,
                directions: [DirectionArrivals(id: "MTA", name: "MTA", trains: [])],
                distanceMeters: $0.location.distance(from: location))
        }
    }

    static func stopIDs(from value: String) -> [String] {
        value.split(whereSeparator: { $0 == ";" || $0 == "," })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func loadStations() async throws -> [CTAStation] {
        if let cached { return cached }
        // MTA station complexes prevent transfer platforms occupying both nearby slots.
        let url = URL(string: "https://data.ny.gov/resource/5f5g-n3cz.json?$limit=5000")!
        let (data, response) = try await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 20))
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        let rows = try JSONDecoder().decode([Row].self, from: data)
        var seen = Set<String>()
        let result = rows.compactMap { row -> CTAStation? in
            guard let lat = Double(row.latitude), let lon = Double(row.longitude),
                  CLLocationCoordinate2DIsValid(.init(latitude: lat, longitude: lon)),
                  !row.stop_name.isEmpty, seen.insert(row.complex_id).inserted else { return nil }
            // Reuse the existing display DTO; these IDs never enter the CTA API/cache.
            return CTAStation(id: "MTA-" + row.complex_id, name: row.stop_name,
                latitude: lat, longitude: lon, mapID: row.complex_id,
                stopIDs: Self.stopIDs(from: row.gtfs_stop_ids))
        }
        guard result.count >= 2 else { throw LiveTransitError.noDirections }
        cached = result
        return result
    }
}
