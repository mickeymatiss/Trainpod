import Foundation

/// Transit adapter for the agency-neutral TP2 arrival board. Firmware and app use TP2 together.
struct LiveTransitFormatter {
    static let maximumPlatforms = 8 // n: increase with the firmware capacity.
    static let maximumStations = 2
    static let platformsPerStation = 4
    static let arrivalsPerPlatform = 9
    static let arrivalsWithoutTimeCutoff = 3
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
                return PlatformPage(stationName: stationLabel(station.station.name),
                             displayDirection: directionLabel(direction.name), trains: direction.trains,
                             distanceValue: distance.value, distanceUnit: distance.unit, isMTA: station.station.id.hasPrefix("MTA-"))
            }
        }.prefix(maximumPlatforms))
    }

    static func distanceLabel(_ meters: Double?) -> (value: String, unit: String) {
        guard let meters, meters.isFinite, meters >= 0, meters / 1609.344 < 9999.95 else { return ("", "mi") }
        let feet = meters / 0.3048
        if meters < 304.8 {
            // Choose units from the actual distance before rounding to hundreds.
            // At 1,000 feet or more, show miles instead.
            return (String(min(1000, Int((feet / 100).rounded()) * 100)), "ft")
        }
        return (distanceMiles(meters), "mi")
    }

    static func distanceMiles(_ meters: Double?) -> String {
        guard let meters, meters.isFinite, meters >= 0, meters / 1609.344 < 9999.95 else { return "" }
        return String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), meters / 1609.344)
    }

    // Shared by the BLE board and compact iOS view; preserve the existing window.
    static func upcomingTrains(_ trains: [CTAArrival], at now: Date = Date()) -> [CTAArrival] {
        Array(trains.filter { $0.arrivalTime >= now }
            .sorted { $0.arrivalTime < $1.arrivalTime }
            .enumerated()
            .filter { $0.offset < arrivalsWithoutTimeCutoff || $0.element.arrivalTime.timeIntervalSince(now) <= arrivalWindowSeconds }
            .prefix(arrivalsPerPlatform)
            .map(\.element))
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
            upcomingTrains(page.trains, at: now).map { train in
                let eta = max(0, min(9999, Int((train.arrivalTime.timeIntervalSince(now) / 60).rounded(.up))))
                return ["A", field(train.routeDisplayName ?? (page.isMTA ? train.route.uppercased() : routeName(for: train.route)), limit: 20), train.routeDisplayColor?.replacingOccurrences(of: "#", with: "") ?? (page.isMTA ? MTARouteStyle.hex(train.route) : routeColorHex(for: train.route)),
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

    // Display labels are intentionally smaller than provider metadata. Keep
    // names/IDs in the source models intact for selection and diagnostics.
    static func stationLabel(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        // CTA decorates names with route lists, e.g. Morgan (Green/Pink).
        // Remove only known route annotations, preserving real name qualifiers.
        guard let start = trimmed.range(of: " (", options: .backwards), trimmed.hasSuffix(")") else { return trimmed }
        let annotation = trimmed[start.upperBound..<trimmed.index(before: trimmed.endIndex)]
        let words = annotation.lowercased().components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty }
        let routeWords: Set<String> = ["red", "blue", "green", "brown", "purple", "pink", "orange", "yellow", "line", "lines", "express", "and", "loop"]
        guard !words.isEmpty, words.allSatisfy({ routeWords.contains($0) }) else { return trimmed }
        return String(trimmed[..<start.lowerBound])
    }

    static func directionLabel(_ value: String) -> String {
        let label = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let directions: [(String, String)] = [
            ("NE", "N. East"), ("NW", "N. West"), ("SE", "S. East"), ("SW", "S. West"),
            ("Northeast", "N. East"), ("Northwest", "N. West"), ("Southeast", "S. East"), ("Southwest", "S. West"),
            ("N. East", "N. East"), ("N. West", "N. West"), ("S. East", "S. East"), ("S. West", "S. West"),
            ("North", "North"), ("South", "South"), ("East", "East"), ("West", "West"),
            ("N", "North"), ("S", "South"), ("E", "East"), ("W", "West"),
            ("Inbound", "Inbound"), ("Outbound", "Outbound"), ("Uptown", "Uptown"), ("Downtown", "Downtown")
        ]
        for (prefix, display) in directions {
            let pattern = "^" + NSRegularExpression.escapedPattern(for: prefix) + "(?:bound)?(?:$|[\\s:/–—(-])"
            if label.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil { return display }
        }
        // Preserve unrecognized agency directions and platform identity; the
        // firmware requires a nonempty label. Never guess a cardinal direction.
        return label.isEmpty ? "Unknown" : label
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

    static func routeName(for route: String) -> String {
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

    static func routeColorHex(for route: String) -> String {
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
