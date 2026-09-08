import Foundation

/// CTA adapter for the agency-neutral TP2 arrival board. Firmware and app use TP2 together.
struct LiveTransitFormatter {
    static func payload(from stations: [StationArrivals]) throws -> Data {
        guard let source = livePayloadSource(from: stations) else { throw LiveTransitError.noDirections }
        let now = Date()
        var rows = source.directions.map { direction in
            direction.trains.sorted { $0.arrivalTime < $1.arrivalTime }.prefix(9).map { train in
                let eta = max(0, min(9999, Int((train.arrivalTime.timeIntervalSince(now) / 60).rounded(.up))))
                return ["A", field(routeName(for: train.route), limit: 20), routeColorHex(for: train.route),
                        field(train.destination, limit: 48), String(eta)].joined(separator: "\t")
            }
        }
        func encoded() -> Data {
            var lines = ["TP2", field(source.station.station.name, limit: 48)]
            for (index, direction) in source.directions.enumerated() {
                lines.append("P\t" + directionLabel(direction.id))
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
        default: return "Direction"
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
