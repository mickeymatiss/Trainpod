import CoreLocation
import Foundation

struct CTAStation: Codable, Identifiable, Equatable {
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
}

struct CTAArrival: Identifiable, Equatable {
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

struct StationArrivals: Identifiable, Equatable {
    var id: String { station.id }

    let station: CTAStation
    let directions: [DirectionArrivals]
}

struct DirectionArrivals: Identifiable, Equatable {
    let id: String
    let name: String
    let trains: [CTAArrival]
}

enum CTAClientError: LocalizedError {
    case invalidURL
    case invalidResponse
    case ctaError(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Could not build the CTA request URL."
        case .invalidResponse: return "CTA returned an unexpected response."
        case .ctaError(let message): return message
        }
    }
}

struct CTAClient {
    private let apiKey = "5dbd9164ce624c06826cbcd6d4eb7d4c"
    private let decoder = JSONDecoder()

    func fetchArrivals(for station: CTAStation, maxArrivals: Int = 20, timeout: TimeInterval = 15) async throws -> [CTAArrival] {
        FileLogger.shared.log("[API] Arrivals request started")
        do {
        guard var components = URLComponents(string: "https://lapi.transitchicago.com/api/1.0/ttarrivals.aspx") else {
            throw CTAClientError.invalidURL
        }

        components.queryItems = [
            URLQueryItem(name: "key", value: apiKey),
            URLQueryItem(name: "mapid", value: station.mapID),
            URLQueryItem(name: "max", value: String(maxArrivals)),
            URLQueryItem(name: "outputType", value: "JSON")
        ]

        guard let url = components.url else {
            throw CTAClientError.invalidURL
        }

        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        let (data, response) = try await URLSession.shared.data(for: request)
        FileLogger.shared.log("[API] Arrivals data received bytes=\(data.count)")
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            FileLogger.shared.log("[API] Invalid response HTTP=\((response as? HTTPURLResponse)?.statusCode ?? 0)")
            throw CTAClientError.invalidResponse
        }

        let payload = try decoder.decode(CTAEnvelope.self, from: data)
        if payload.ctatt.errorCode != "0" {
            FileLogger.shared.log("[API] CTA returned an error")
            throw CTAClientError.ctaError(payload.ctatt.errorName ?? "CTA request failed.")
        }

        return payload.ctatt.eta.compactMap { eta in
            guard let arrivalTime = CTAClient.date(from: eta.arrivalTime) else {
                return nil
            }

            return CTAArrival(
                id: "\(station.mapID)-\(eta.stopID)-\(eta.runNumber)-\(eta.arrivalTime)",
                route: eta.route,
                destination: eta.destination,
                arrivalTime: arrivalTime,
                approaching: eta.isApproaching == "1",
                delayed: eta.isDelayed == "1",
                stationName: eta.stationName,
                stopDescription: eta.stopDescription,
                directionID: station.stopDirections?[eta.stopID] ?? eta.trainDirection
            )
        }
        } catch {
            FileLogger.shared.log("[API] Request failed code=\((error as NSError).code) invalidData=\(error is DecodingError)")
            throw error
        }
    }

    private static func date(from timestamp: String) -> Date? {
        for formatter in ctaDateFormatters {
            if let date = formatter.date(from: timestamp) {
                return date
            }
        }
        return nil
    }

    private static let ctaDateFormatters: [DateFormatter] = [
        makeDateFormatter(format: "yyyy-MM-dd'T'HH:mm:ss"),
        makeDateFormatter(format: "yyyyMMdd HH:mm:ss")
    ]

    private static func makeDateFormatter(format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "America/Chicago")
        formatter.dateFormat = format
        return formatter
    }
}

private struct CTAEnvelope: Decodable {
    let ctatt: CTAArrivalsPayload
}

private struct CTAArrivalsPayload: Decodable {
    let timestamp: String
    let errorCode: String
    let errorName: String?
    let eta: [CTAEta]

    enum CodingKeys: String, CodingKey {
        case timestamp = "tmst"
        case errorCode = "errCd"
        case errorName = "errNm"
        case eta
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        timestamp = try container.decode(String.self, forKey: .timestamp)
        errorCode = try container.decodeIfPresent(String.self, forKey: .errorCode) ?? "0"
        errorName = try container.decodeIfPresent(String.self, forKey: .errorName)
        eta = try container.decodeIfPresent([CTAEta].self, forKey: .eta) ?? []
    }
}

private struct CTAEta: Decodable {
    let route: String
    let destination: String
    let arrivalTime: String
    let isApproaching: String
    let isDelayed: String
    let runNumber: String
    let stationName: String
    let stopID: String
    let stopDescription: String
    let trainDirection: String

    enum CodingKeys: String, CodingKey {
        case route = "rt"
        case destination = "destNm"
        case arrivalTime = "arrT"
        case isApproaching = "isApp"
        case isDelayed = "isDly"
        case runNumber = "rn"
        case stationName = "staNm"
        case stopID = "stpId"
        case stopDescription = "stpDe"
        case trainDirection = "trDr"
    }
}
