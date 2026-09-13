import Foundation

// Only application diagnostics/errors are stubbed; production parser, selector and formatter are compiled below.
final class FileLogger { static let shared = FileLogger(); func log(_ text: String) {} }
enum LiveTransitError: Error { case noDirections, payloadTooLarge, platformCapacityExceeded }

@main struct Tests {
    static func v(_ n: UInt64) -> [UInt8] {
        var n = n, bytes: [UInt8] = []
        repeat { let b = UInt8(n & 127); n >>= 7; bytes.append(b | (n == 0 ? 0 : 128)) } while n != 0
        return bytes
    }
    static func number(_ field: UInt64, _ value: UInt64) -> [UInt8] { v(field << 3) + v(value) }
    static func message(_ field: UInt64, _ value: [UInt8]) -> [UInt8] { v(field << 3 | 2) + v(UInt64(value.count)) + value }
    static func string(_ field: UInt64, _ value: String) -> [UInt8] { message(field, Array(value.utf8)) }
    static func entity(_ id: String, _ route: String, _ stop: String, _ time: UInt64, relationship: UInt64 = 0, stopRelationship: UInt64 = 0, departure: Bool = false, deleted: Bool = false, nyctDirection: UInt64? = nil) -> [UInt8] {
        let extensionFields = nyctDirection.map { message(1001, number(3, $0)) } ?? []
        let trip = string(1, id) + string(3, "20260912") + string(5, route) + number(4, relationship) + extensionFields
        let update = string(4, stop) + message(departure ? 3 : 2, number(2, time)) + number(5, stopRelationship)
        return message(2, string(1, id) + number(2, deleted ? 1 : 0) + message(3, message(1, trip) + message(2, update)))
    }
    @MainActor static func main() throws {
        assert(MTALocationMode.current.locationOverride == nil)
        assert(MTALocationMode.timesSquare.locationOverride!.coordinate.latitude == 40.755746)
        assert(MTALocationMode.timesSquare.locationOverride!.coordinate.longitude == -73.9875808)
        assert(MTAStationRepository.stopIDs(from: "127; 725; 902; A27; R16") == ["127", "725", "902", "A27", "R16"])
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970)), t = UInt64(now.timeIntervalSince1970)
        let header = message(1, string(1, "1.0") + number(3, t))
        let entities = entity("later", "G", "A01N", t + 300)
            + entity("first", "G", "A01S", t + 60)
            + entity("first", "G", "A02S", t + 120)
            + entity("second", "F", "A01N", t + 180, departure: true)
            + entity("past", "G", "A01N", t - 1)
            + entity("cancelled", "G", "A01N", t + 1, relationship: 3)
            + entity("skipped", "G", "A01N", t + 1, stopRelationship: 1)
            + entity("no-data", "G", "A01N", t + 1, stopRelationship: 2)
            + entity("deleted", "G", "A01N", t + 1, deleted: true)
            + entity("unrelated", "G", "A010N", t + 1)
            + entity("station2", "7", "B01N", t + 30)
        let feed = try MTAGTFSRealtime.decode(Data(header + entities + number(1001, 42)))
        assert(feed.predictions.count == 7)
        assert(MTAClient.isFresh(feed, now: now))
        assert(!MTAClient.isFresh(feed, now: now.addingTimeInterval(301)))
        func station(_ id: String, _ stops: [String]) -> StationArrivals {
            StationArrivals(station: CTAStation(id: "MTA-" + id, name: id, latitude: 40, longitude: -73, mapID: id, stopIDs: stops), directions: [], distanceMeters: 100)
        }
        let stations = [station("One", ["A01", "A02"]), station("Two", ["B01"])]
        let result = MTAClient.nextTrains(for: stations, predictions: feed.predictions, now: now)
        assert(result[0].directions.map(\.id) == ["N", "S"])
        assert(result[0].directions.map(\.name) == ["Northbound", "Southbound"])
        assert(result[0].directions[0].trains.map(\.route) == ["F", "G"])
        assert(result[0].directions[1].trains.map(\.route) == ["G"])
        let first = result[0].directions.flatMap(\.trains).sorted { $0.arrivalTime < $1.arrivalTime }
        assert(first.count == 3 && first[0].route == "G" && first[1].route == "F")
        assert(first[0].destination == "Southbound" && first[1].destination == "Northbound")
        assert(result[1].directions[0].trains.count == 1 && result[1].directions[1].trains.isEmpty)
        assert(MTAClient.nextTrains(for: [station("Empty", ["Z99"])], predictions: feed.predictions, now: now)[0].directions[0].trains.isEmpty)
        for bytes in [Data([0x80]), Data([0x0a, 0xff]), Data(repeating: 0xff, count: 12), Data(header + [0])] {
            do { _ = try MTAGTFSRealtime.decode(bytes); assertionFailure("Malformed protobuf accepted") } catch {}
        }
        do {
            _ = try MTAGTFSRealtime.decode(Data(message(1, string(1, "2.0") + number(2, 1) + number(3, t))))
            assertionFailure("Differential feed accepted")
        } catch {}
        // NYCT's explicit direction wins over stop suffixes, including east/west.
        for (value, expected) in [(UInt64(1), MTADirection.north), (2, .east), (3, .south), (4, .west)] {
            let decoded = try MTAGTFSRealtime.decode(Data(header + entity("axis", "L", "A01N", t + 60, nyctDirection: value)))
            assert(decoded.predictions[0].direction == expected)
            assert(MTADirection.resolve(decoded.predictions[0]) == expected)
        }
        let bareStop = MTAGTFSRealtime.Prediction(tripID: "bare", route: "X", stopID: "STATION", time: now)
        assert(MTADirection.resolve(bareStop, allowStopSuffix: false) == .unknown)
        let axes: [MTAGTFSRealtime.Prediction] = [
            .init(tripID: "east-explicit", route: "L", stopID: "A01N", time: now.addingTimeInterval(60), direction: .east),
            .init(tripID: "east-suffix", route: "7", stopID: "A02E", time: now.addingTimeInterval(120)),
            .init(tripID: "west", route: "L", stopID: "A01S", time: now.addingTimeInterval(180), direction: .west)
        ]
        let eastWest = MTAClient.nextTrains(for: [stations[0]], predictions: axes, now: now)
        assert(eastWest[0].directions.map(\.name) == ["Eastbound", "Westbound"])
        assert(eastWest[0].directions[0].trains.map(\.route) == ["L", "7"])
        let eastWestText = String(decoding: try LiveTransitFormatter.payload(from: eastWest), as: UTF8.self)
        assert(eastWestText.contains("P\tEastbound\t") && eastWestText.contains("P\tWestbound\t"))
        let unknown = MTAClient.nextTrains(for: [stations[0]], predictions: [
            .init(tripID: "unknown", route: "X", stopID: "A01", time: now.addingTimeInterval(60))
        ], now: now)
        assert(unknown[0].directions[0].name == "Direction TBD")
        let mixed = MTAClient.nextTrains(for: [stations[0]], predictions: axes + feed.predictions, now: now)
        assert(mixed[0].directions.count == 4)
        do {
            _ = try LiveTransitFormatter.payload(from: mixed)
            assertionFailure("Extra platform groups silently truncated")
        } catch LiveTransitError.platformCapacityExceeded {} catch { throw error }
        let ctaStation = CTAStation(id: "CTA-one", name: "CTA", latitude: 41, longitude: -87, mapID: "1", stopIDs: ["1"])
        let cta = StationArrivals(station: ctaStation, directions: [DirectionArrivals(id: "N", name: "North", trains: [first[0]])])
        let ctaPayload = String(decoding: try LiveTransitFormatter.payload(from: [cta]), as: UTF8.self)
        assert(ctaPayload.contains("A\tGreen\t009B3A\t"))
        // App retains nine unique trains in time order, while BLE keeps two.
        let many = (1...12).reversed().map { index in
            MTAGTFSRealtime.Prediction(tripID: "trip-\(index)", route: "G", stopID: "A01N",
                time: now.addingTimeInterval(Double(index * 60)))
        }
        let nine = MTAClient.nextTrains(for: [stations[0]], predictions: many + [many[0]], now: now)
        let visible = nine[0].directions[0].trains
        assert(visible.count == 9 && visible.first!.id == "trip-1" && visible.last!.id == "trip-9")
        let deviceText = String(decoding: try LiveTransitFormatter.payload(from: nine), as: UTF8.self)
        assert(deviceText.split(separator: "\n").filter { $0.hasPrefix("A\t") }.count == 9)
        let payload = try LiveTransitFormatter.payload(from: result)
        let text = String(decoding: payload, as: UTF8.self)
        assert(text.hasPrefix("TP2\n") && text.contains("A\tG\t6CBE45\tSouthbound\t"))
        assert(text.split(separator: "\n").filter { $0.hasPrefix("P\t") }.count == 4)
        try payload.write(to: URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "/tmp/trainpod-mta-payload.txt"))
        var total = 0
        for path in CommandLine.arguments.dropFirst(2) {
            let name = URL(fileURLWithPath: path).lastPathComponent
            let live = try MTAGTFSRealtime.decode(Data(contentsOf: URL(fileURLWithPath: path)))
            total += live.predictions.count
            print("\(name): \(live.predictions.count) predictions, age \(Int(Date().timeIntervalSince(live.timestamp))) seconds")
        }
        print("Parser, skipped/cancelled trips, exact stop matching, deduplication, next-nine app selection and nine-train-per-platform device limit, freshness and TP2 formatting passed. Live predictions: \(total).")
    }
}
