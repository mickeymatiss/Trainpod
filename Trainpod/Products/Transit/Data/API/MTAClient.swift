import Foundation

@MainActor
final class MTAClient {
    static let shared = MTAClient()
    // Query all subway groups so rerouted lines are included at a station complex.
    static let feeds = ["gtfs", "gtfs-ace", "gtfs-bdfm", "gtfs-g", "gtfs-jz", "gtfs-nqrw", "gtfs-l", "gtfs-si"]
    private var cached: (feeds: [MTAGTFSRealtime.Feed], fetchedAt: Date)?
    private var inFlight: Task<[MTAGTFSRealtime.Feed], Error>?

    enum FeedError: LocalizedError {
        case stale
        var errorDescription: String? { "MTA live arrivals are temporarily unavailable. Please try again." }
    }

    func arrivals(for stations: [StationArrivals], maxAge: TimeInterval = 30) async throws -> [StationArrivals] {
        let feeds = try await currentFeeds(maxAge: maxAge)
        try Task.checkCancellation()
        let now = Date()
        guard feeds.allSatisfy({ Self.isFresh($0, now: now) }) else { throw FeedError.stale }
        return Self.nextTrains(for: stations, predictions: feeds.flatMap(\.predictions), now: now)
    }

    static func isFresh(_ feed: MTAGTFSRealtime.Feed, now: Date) -> Bool {
        (-60...300).contains(now.timeIntervalSince(feed.timestamp))
    }

    private func currentFeeds(maxAge: TimeInterval) async throws -> [MTAGTFSRealtime.Feed] {
        if let cached, (0...maxAge).contains(Date().timeIntervalSince(cached.fetchedAt)),
           cached.feeds.allSatisfy({ Self.isFresh($0, now: Date()) }) {
            FileLogger.shared.log("[BLE-REQ] Cache hit id=\(PhoneDiagnosticContext.transactionId ?? "local") age=\(Int(Date().timeIntervalSince(cached.fetchedAt)))s")
            return cached.feeds
        }
        if let inFlight { return try await inFlight.value }
        FileLogger.shared.log("[BLE-REQ] Cache stale/missing id=\(PhoneDiagnosticContext.transactionId ?? "local"); starting station fetch")
        let task = Task {
            try await withThrowingTaskGroup(of: MTAGTFSRealtime.Feed.self) { group in
                for name in Self.feeds {
                    group.addTask {
                        let url = URL(string: "https://api-endpoint.mta.info/Dataservice/mtagtfsfeeds/nyct%2F" + name)!
                        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
                        request.setValue("application/x-protobuf", forHTTPHeaderField: "Accept")
                        let (data, response) = try await URLSession.shared.data(for: request)
                        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                        return try await MTAGTFSRealtime.decode(data)
                    }
                }
                var result: [MTAGTFSRealtime.Feed] = []
                for try await feed in group { result.append(feed) }
                return result
            }
        }
        inFlight = task
        defer { inFlight = nil }
        let feeds = try await task.value
        guard feeds.allSatisfy({ Self.isFresh($0, now: Date()) }) else { throw FeedError.stale }
        cached = (feeds, Date())
        return feeds
    }

    static func nextTrains(for stations: [StationArrivals], predictions: [MTAGTFSRealtime.Prediction], now: Date) -> [StationArrivals] {
        stations.map { station in
            let stops = Set(station.station.stopIDs)
            let matching = predictions.filter {
                guard $0.time >= now else { return false }
                if stops.contains($0.stopID) { return true }
                guard let suffix = $0.stopID.last,
                      ["N", "S", "E", "W"].contains(String(suffix)) else { return false }
                return stops.contains(String($0.stopID.dropLast()))
            }.sorted { $0.time == $1.time ? $0.tripID < $1.tripID : $0.time < $1.time }
            // A trip may call at multiple constituent stops in the same transfer complex.
            var seen = Set<String>()
            let trains = matching.filter { seen.insert($0.tripID).inserted }.prefix(9).map { prediction in
                let direction = MTADirection.resolve(prediction, allowStopSuffix: !stops.contains(prediction.stopID))
                return CTAArrival(id: prediction.tripID, route: prediction.route,
                    destination: direction.label, arrivalTime: prediction.time,
                    approaching: prediction.time.timeIntervalSince(now) < 60, delayed: false,
                    stationName: station.station.name, stopDescription: direction.label, directionID: direction.rawValue)
            }
            // Consider all matching predictions before the nine-train cutoff, so a
            // busy direction cannot hide the other direction's platform entirely.
            var directions = Set(matching.map { MTADirection.resolve($0, allowStopSuffix: !stops.contains($0.stopID)) })
            if directions.isEmpty { directions.insert(.unknown) }
            if directions.count == 1, let only = directions.first, only != .unknown {
                directions.insert(only.opposite)
            }
            let platforms = MTADirection.allCases.filter { directions.contains($0) }.map { direction in
                DirectionArrivals(id: direction.rawValue, name: direction.label,
                    trains: trains.filter { $0.directionID == direction.rawValue })
            }
            return StationArrivals(station: station.station,
                directions: platforms,
                distanceMeters: station.distanceMeters)
        }
    }
}

/// MTA route identities stay distinct from CTA color names (especially the G train).
enum MTARouteStyle {
    static func hex(_ route: String) -> String {
        switch route.uppercased() {
        case "1", "2", "3": return "EE352E"
        case "4", "5", "6", "6X": return "00933C"
        case "7", "7X": return "B933AD"
        case "A", "C", "E": return "0039A6"
        case "B", "D", "F", "FX", "M": return "FF6319"
        case "G": return "6CBE45"
        case "J", "Z": return "996633"
        case "N", "Q", "R", "W": return "FCCC0A"
        case "L": return "A7A9AC"
        case "SI", "SIR": return "0039A6"
        default: return "808183"
        }
    }
}
