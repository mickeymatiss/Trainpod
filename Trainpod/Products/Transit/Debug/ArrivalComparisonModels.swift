import Foundation

nonisolated enum ArrivalSource: String, Sendable { case legacy, normalized }

nonisolated struct ComparableArrival: Identifiable, Sendable {
    let id: String
    let source: ArrivalSource
    let stationId: String?
    let platformId: String?
    let direction: String?
    let routeId: String
    let tripId: String?
    let destination: String?
    let arrivalAt: Date
    var routeName: String? = nil
    var routeColor: String? = nil
    var identityNote: String? = nil
}

nonisolated enum ArrivalMatch: String, Sendable {
    case identity = "ID MATCH", approximate = "APPROXIMATE", legacyOnly = "LEGACY ONLY", normalizedOnly = "NORMALIZED ONLY"
}

nonisolated struct ArrivalComparisonRow: Identifiable, Sendable {
    let legacy: ComparableArrival?
    let normalized: ComparableArrival?
    let match: ArrivalMatch
    var id: String { (legacy?.id ?? "-") + "|" + (normalized?.id ?? "-") }
    var arrival: ComparableArrival { normalized ?? legacy! }
    var deltaSeconds: TimeInterval? {
        guard let legacy, let normalized else { return nil }
        return normalized.arrivalAt.timeIntervalSince(legacy.arrivalAt)
    }
    var group: String {
        let direction = normalized?.direction ?? legacy?.direction
        let platform = normalized?.platformId ?? legacy?.platformId
        if let platform { return "Platform \(platform)" }
        return direction.map { "Direction \($0)" } ?? "Unresolved platform/direction"
    }
}

nonisolated struct ArrivalComparisonSummary: Sendable {
    let destinationMismatches: Int
    let platformMismatches: Int
    let matched: Int
    let legacyOnly: Int
    let normalizedOnly: Int
    let medianAbsoluteDelta: TimeInterval?
    let maxAbsoluteDelta: TimeInterval?
    init(rows: [ArrivalComparisonRow]) {
        destinationMismatches = rows.filter {
            guard let a = $0.legacy?.destination, let b = $0.normalized?.destination else { return false }
            return a.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(b.trimmingCharacters(in: .whitespacesAndNewlines)) != .orderedSame
        }.count
        let unmatchedNew = rows.filter { $0.match == .normalizedOnly }.compactMap(\.normalized)
        platformMismatches = rows.filter { $0.match == .legacyOnly }.compactMap(\.legacy).filter { a in
            guard let station = a.stationId, let trip = a.tripId, let platform = a.platformId else { return false }
            return unmatchedNew.contains { b in
                b.stationId == station && b.tripId == trip && b.routeId == a.routeId
                    && b.platformId != nil && b.platformId != platform
            }
        }.count
        let deltas = rows.compactMap(\.deltaSeconds).map(abs).sorted()
        matched = deltas.count
        legacyOnly = rows.filter { $0.match == .legacyOnly }.count
        normalizedOnly = rows.filter { $0.match == .normalizedOnly }.count
        maxAbsoluteDelta = deltas.last
        if deltas.isEmpty { medianAbsoluteDelta = nil }
        else {
            let middle = deltas.count / 2
            medianAbsoluteDelta = deltas.count.isMultiple(of: 2)
                ? (deltas[middle - 1] + deltas[middle]) / 2 : deltas[middle]
        }
    }
}

nonisolated enum ArrivalComparison {
    static func normalized(_ arrivals: [ResolvedTransitArrival]) -> [ComparableArrival] {
        arrivals.enumerated().map { index, a in
            ComparableArrival(id: "normalized-\(index)", source: .normalized,
                stationId: a.stationId, platformId: a.platformId, direction: a.direction,
                routeId: a.routeId, tripId: a.tripId, destination: a.destinationName,
                arrivalAt: a.arrivalAt, routeName: a.routeName, routeColor: a.routeColor)
        }
    }

    static func rows(legacy: [ComparableArrival], normalized: [ComparableArrival]) -> [ArrivalComparisonRow] {
        struct Edge { let left: Int; let right: Int; let distance: Double }
        var usedLeft = Set<Int>(), usedRight = Set<Int>()
        var ambiguousLeft = Set<Int>(), ambiguousRight = Set<Int>()
        var result: [ArrivalComparisonRow] = []
        for strong in [true, false] {
            var edges: [Edge] = []
            for (i, a) in legacy.enumerated() where !usedLeft.contains(i) && !ambiguousLeft.contains(i) {
                for (j, b) in normalized.enumerated() where !usedRight.contains(j) && !ambiguousRight.contains(j) {
                    guard sameContext(a, b) else { continue }
                    let distance = abs(b.arrivalAt.timeIntervalSince(a.arrivalAt))
                    if strong {
                        guard let trip = a.tripId, !trip.isEmpty, trip == b.tripId else { continue }
                    } else {
                        guard distance <= 300 else { continue }
                        if let a = a.destination, let b = b.destination, canonical(a) != canonical(b) { continue }
                    }
                    edges.append(Edge(left: i, right: j, distance: distance))
                }
            }
            edges.sort { ($0.distance, $0.left, $0.right) < ($1.distance, $1.left, $1.right) }
            for edge in edges where !usedLeft.contains(edge.left) && !usedRight.contains(edge.right)
                && !ambiguousLeft.contains(edge.left) && !ambiguousRight.contains(edge.right) {
                // Equal-distance alternatives are ambiguous; retain both as unmatched.
                let tied = edges.contains { other in
                    (other.left != edge.left || other.right != edge.right)
                        && (other.left == edge.left || other.right == edge.right)
                        && !usedLeft.contains(other.left) && !usedRight.contains(other.right)
                        && abs(other.distance - edge.distance) < 0.001
                }
                if tied {
                    ambiguousLeft.insert(edge.left)
                    ambiguousRight.insert(edge.right)
                    for other in edges where abs(other.distance - edge.distance) < 0.001
                        && (other.left == edge.left || other.right == edge.right) {
                        ambiguousLeft.insert(other.left)
                        ambiguousRight.insert(other.right)
                    }
                    continue
                }
                usedLeft.insert(edge.left); usedRight.insert(edge.right)
                result.append(ArrivalComparisonRow(legacy: legacy[edge.left], normalized: normalized[edge.right],
                    match: strong ? .identity : .approximate))
            }
        }
        for (i, arrival) in legacy.enumerated() where !usedLeft.contains(i) {
            result.append(ArrivalComparisonRow(legacy: arrival, normalized: nil, match: .legacyOnly))
        }
        for (i, arrival) in normalized.enumerated() where !usedRight.contains(i) {
            result.append(ArrivalComparisonRow(legacy: nil, normalized: arrival, match: .normalizedOnly))
        }
        return result.sorted {
            ($0.group, $0.arrival.arrivalAt, $0.id) < ($1.group, $1.arrival.arrivalAt, $1.id)
        }
    }

    private static func sameContext(_ a: ComparableArrival, _ b: ComparableArrival) -> Bool {
        guard let station = a.stationId, station == b.stationId, a.routeId == b.routeId else { return false }
        if let left = a.platformId, let right = b.platformId { return left == right }
        guard let left = a.direction, let right = b.direction, !left.isEmpty, left != "?" else { return false }
        return canonical(left) == canonical(right)
    }

    private static func canonical(_ value: String) -> String {
        value.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }

    static func signedDelta(_ seconds: TimeInterval) -> String {
        let magnitude = Int(abs(seconds).rounded())
        let sign = seconds < 0 ? "−" : "+"
        return magnitude >= 60 ? "\(sign)\(magnitude / 60)m \(magnitude % 60)s" : "\(sign)\(magnitude)s"
    }
}
