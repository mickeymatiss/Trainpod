import Foundation

@main struct PlatformFormatterTest {
    static func main() throws {
        let trains = (0..<6).reversed().map {
            CTAArrival(id: "train-\($0)", route: "red", destination: "Howard", arrivalTime: Date().addingTimeInterval(Double($0 + 1) * 60 - 30), approaching: false, delayed: false, stationName: "", stopDescription: "", directionID: "N")
        }
        func station(_ name: String, _ names: [String]) -> StationArrivals {
            StationArrivals(station: CTAStation(id: name, name: name, latitude: 41, longitude: -87, mapID: "1", stopIDs: ["1"]), directions: names.map {
                DirectionArrivals(id: "raw-\($0)", name: $0, trains: trains)
            })
        }
        var grand = station("Grand", ["South", "North"])
        var chicago = station("Chicago", ["South", "North"])
        grand.distanceMeters = 0.7 * 1609.344
        chicago.distanceMeters = 1.2 * 1609.344
        precondition(LiveTransitFormatter.distanceMiles(1.8 * 1609.344) == "1.8")
        precondition(LiveTransitFormatter.distanceMiles(nil).isEmpty)
        precondition(LiveTransitFormatter.distanceMiles(-1).isEmpty)
        precondition(LiveTransitFormatter.distanceMiles(.infinity).isEmpty)
        precondition(LiveTransitFormatter.distanceMiles(0) == "0.0")
        let pages = LiveTransitFormatter.platformPages(from: [grand, chicago])
        precondition(pages.map(\.stationName) == ["Grand", "Grand", "Chicago", "Chicago"])
        precondition(pages.map(\.displayDirection) == ["North", "South", "North", "South"])
        let payload = try LiveTransitFormatter.payload(from: [grand, chicago])
        let text = String(decoding: payload, as: UTF8.self)
        precondition(text.contains("P\tNorth\tGrand\t0.7"))
        precondition(text.contains("P\tNorth\tChicago\t1.2"))
        precondition(text.components(separatedBy: "\nA\t").count - 1 == 24)
        precondition(payload.count <= 2048)
        precondition(LiveTransitFormatter.platformPages(from: [grand]).count == 2)
        precondition(LiveTransitFormatter.platformPages(from: [grand, station("Loop", ["Clockwise"])]).count == 3)
        let custom = try LiveTransitFormatter.payload(from: [station("Loop", ["Clockwise"])])
        precondition(String(decoding: custom, as: UTF8.self).contains("P\tClockwise\tLoop"))
        precondition(LiveTransitFormatter.platformPages(from: [station("Hub", ["A", "B", "C"]), chicago]).count == 4)
        do { _ = try LiveTransitFormatter.payload(from: []); preconditionFailure("Empty pages must fail") }
        catch LiveTransitError.noDirections {}
        if CommandLine.arguments.count > 1 { try payload.write(to: URL(fileURLWithPath: CommandLine.arguments[1])) }
        print("PASS station-major order, 1-4 pages, up to nine arrivals per platform, normalized directions, bounded payload (\(payload.count) bytes)")
    }
}
