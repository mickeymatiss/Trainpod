import Foundation

/// Transit adapter for the agency-neutral TP2 arrival board. Firmware and app use TP2 together.
struct LiveTransitFormatter {
    static let maximumPlatforms = 4 // n: increase with the firmware capacity.
    static let maximumStations = 2
    static let platformsPerStation = 2
    static let arrivalsPerPlatform = 9
    static let arrivalWindowSeconds: TimeInterval = 30 * 60

    struct PlatformPage {
        let stationName: String
        let displayDirection: String
        let trains: [CTAArrival]
        let distanceValue: String
        let distanceUnit: String
        var isMTA: Bool = false
    }

    static func platformPages(from stations: [StationArrivals]) -> [PlatformPage] {
        Array(stations.filter { !$0.directions.isEmpty }.prefix(maximumStations).flatMap { station in
            station.directions.sorted {
                $0.name == $1.name ? $0.id < $1.id : $0.name < $1.name
            }.prefix(platformsPerStation).map { direction in
                let distance = distanceLabel(station.distanceMeters)
                return PlatformPage(stationName: station.station.name,
                             displayDirection: direction.name, trains: direction.trains,
                             distanceValue: distance.value, distanceUnit: distance.unit, isMTA: station.station.id.hasPrefix("MTA-"))
            }
        }.prefix(maximumPlatforms))
    }

    static func distanceLabel(_ meters: Double?) -> (value: String, unit: String) {
        guard let meters, meters.isFinite, meters >= 0, meters / 1609.344 < 9999.95 else { return ("", "mi") }
        let feet = meters / 0.3048
        if meters <= 609.6 {
            // Choose the unit before rounding: 2,000 feet or less stays in feet.
            return (String(min(2000, Int((feet / 100).rounded()) * 100)), "ft")
        }
        return (distanceMiles(meters), "mi")
    }

    static func distanceMiles(_ meters: Double?) -> String {
        guard let meters, meters.isFinite, meters >= 0, meters / 1609.344 < 9999.95 else { return "" }
        return String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), meters / 1609.344)
    }

    static func payload(from stations: [StationArrivals]) throws -> Data {
        // Do not silently discard unusual mixed-axis/unknown MTA buckets.
        guard !stations.prefix(maximumStations).contains(where: {
            $0.station.id.hasPrefix("MTA-") && $0.directions.count > platformsPerStation
        }) else { throw LiveTransitError.platformCapacityExceeded }
        let pages = platformPages(from: stations)
        guard !pages.isEmpty else { throw LiveTransitError.noDirections }
        let now = Date()
        var rows = pages.map { page in
            page.trains.filter {
                let remaining = $0.arrivalTime.timeIntervalSince(now)
                return remaining >= 0 && remaining <= arrivalWindowSeconds
            }.sorted { $0.arrivalTime < $1.arrivalTime }.prefix(arrivalsPerPlatform).map { train in
                let eta = max(0, min(9999, Int((train.arrivalTime.timeIntervalSince(now) / 60).rounded(.up))))
                return ["A", field(page.isMTA ? train.route.uppercased() : routeName(for: train.route), limit: 20), page.isMTA ? MTARouteStyle.hex(train.route) : routeColorHex(for: train.route),
                        field(train.destination, limit: 48), String(eta)].joined(separator: "\t")
            }
        }
        func encoded() -> Data {
            var lines = ["TP2", field(pages[0].stationName, limit: 48)]
            for (index, page) in pages.enumerated() {
                // Optional station field extends the existing compact P record.
                lines.append(["P", field(page.displayDirection, limit: 16),
                              field(page.stationName, limit: 48), page.distanceValue, page.distanceUnit].joined(separator: "\t"))
                lines.append(contentsOf: rows[index])
            }
            return TransitMessage.completePayload(lines.joined(separator: "\n") + "\n")
        }
        var data = encoded()
        // Drop only furthest arrivals if unusually long names exceed the BLE text limit.
        while data.count > 2048 {
            guard let index = rows.indices.filter({ !rows[$0].isEmpty }).max(by: { rows[$0].count < rows[$1].count }) else {
                throw LiveTransitError.payloadTooLarge
            }
            rows[index].removeLast()
            data = encoded()
        }
        FileLogger.shared.log("[TRANSIT] Built \(pages.count) platform pages")
        return data
    }

    static func directionLabel(_ id: String) -> String {
        switch id.uppercased() {
        case "N": return "North"
        case "S": return "South"
        case "E": return "East"
        case "W": return "West"
        case "NE": return "N. East"
        case "NW": return "N. West"
        case "SE": return "S. East"
        case "SW": return "S. West"
        default: return id
        }
    }

    private static func field(_ value: String, limit: Int) -> String {
        let latin = value.applyingTransform(.toLatin, reverse: false)?
            .applyingTransform(.stripCombiningMarks, reverse: false) ?? value
        let ascii = latin.unicodeScalars.map { scalar -> String in
            (32...126).contains(scalar.value) ? String(scalar) : " "
        }.joined()
        return String(ascii.prefix(limit))
    }

    static func livePayloadSource(from stationArrivals: [StationArrivals]) -> (station: StationArrivals, directions: [DirectionArrivals])? {
        guard let station = stationArrivals.first(where: { !$0.directions.isEmpty }) else { return nil }
        return (station, Array(station.directions.prefix(4)))
    }

    private static func routeName(for route: String) -> String {
        switch route.lowercased() {
        case "g": return "Green"
        case "brn": return "Brown"
        case "org": return "Orange"
        case "p": return "Purple"
        case "pexp": return "Purple Express"
        case "pnk", "pink": return "Pink"
        case "y": return "Yellow"
        default: return route.capitalized
        }
    }

    private static func routeColorHex(for route: String) -> String {
        switch route.lowercased() {
        case "red": return "C60C30"
        case "blue": return "00A1DE"
        case "brn": return "62361B"
        case "g": return "009B3A"
        case "org": return "F9461C"
        case "p", "pexp": return "522398"
        case "pnk", "pink": return "E27EA6"
        case "y": return "F9E300"
        default: return "FFFFFF"
        }
    }

}
