import Foundation

/// Small, bounds-checked reader for the GTFS-RT TripUpdate subset used by MTA.
/// Unknown protobuf fields (including NYCT extensions) are skipped. No generated-code dependency.
enum MTAGTFSRealtime {
    struct Prediction: Sendable {
        let tripID: String
        let route: String
        let stopID: String
        let time: Date
        var direction: MTADirection? = nil
    }
    struct Feed: Sendable {
        let timestamp: Date
        let predictions: [Prediction]
    }
    enum DecodeError: Error { case malformed, unsupportedFeed }

    private struct Field {
        let number: Int
        var integer: UInt64? = nil
        var bytes: [UInt8]? = nil
    }
    private struct Message {
        let fields: [Field]
        init(_ bytes: [UInt8]) throws {
            var offset = 0
            func varint() throws -> UInt64 {
                var result: UInt64 = 0
                for shift in stride(from: 0, through: 63, by: 7) {
                    guard offset < bytes.count else { throw DecodeError.malformed }
                    let byte = bytes[offset]; offset += 1
                    guard shift < 63 || byte <= 1 else { throw DecodeError.malformed }
                    result |= UInt64(byte & 0x7f) << shift
                    if byte & 0x80 == 0 { return result }
                }
                throw DecodeError.malformed
            }
            var result: [Field] = []
            while offset < bytes.count {
                let tag = try varint()
                guard tag >> 3 > 0, tag >> 3 <= 536_870_911 else { throw DecodeError.malformed }
                var field = Field(number: Int(tag >> 3))
                switch tag & 7 {
                case 0: field.integer = try varint()
                case 2:
                    let length = try varint()
                    guard length <= UInt64(bytes.count - offset) else { throw DecodeError.malformed }
                    let end = offset + Int(length)
                    field.bytes = Array(bytes[offset..<end]); offset = end
                case 1, 5:
                    let length = tag & 7 == 1 ? 8 : 4
                    guard length <= bytes.count - offset else { throw DecodeError.malformed }
                    offset += length
                default: throw DecodeError.malformed
                }
                result.append(field)
            }
            fields = result
        }
        func uint(_ n: Int) -> UInt64? { fields.last { $0.number == n }?.integer }
        func string(_ n: Int) -> String? {
            fields.last { $0.number == n }?.bytes.flatMap { String(bytes: $0, encoding: .utf8) }
        }
        func messages(_ n: Int) throws -> [Message] {
            try fields.filter { $0.number == n }.map {
                guard let bytes = $0.bytes else { throw DecodeError.malformed }
                return try Message(bytes)
            }
        }
    }

    static func decode(_ data: Data) throws -> Feed {
        guard !data.isEmpty, data.count <= 8_000_000 else { throw DecodeError.malformed }
        let root = try Message(Array(data))
        guard let header = try root.messages(1).first,
              let version = header.string(1), ["1.0", "2.0"].contains(version),
              header.uint(2) ?? 0 == 0, let timestamp = header.uint(3), timestamp > 0 else {
            throw DecodeError.unsupportedFeed
        }
        var predictions: [Prediction] = []
        for entity in try root.messages(2) where entity.uint(2) != 1 {
            guard let update = try entity.messages(3).first,
                  let trip = try update.messages(1).first,
                  let id = trip.string(1), !id.isEmpty,
                  let route = trip.string(5), !route.isEmpty else { continue }
            // CANCELED, DELETED, REPLACEMENT and unknown relationships are not boardable predictions.
            guard [UInt64(0), 1, 2, 6].contains(trip.uint(4) ?? 0) else { continue }
            if let updated = update.uint(4), updated < timestamp, timestamp - updated > 300 { continue }
            let nyct = try trip.messages(1001).first
            let direction = nyct?.uint(3).flatMap { MTADirection(nyctValue: $0) }
            let tripID = [route, trip.string(3) ?? "", trip.string(2) ?? "", id].joined(separator: "/")
            for stop in try update.messages(2) {
                // SKIPPED and NO_DATA must not become arrivals even if a time is present.
                guard [UInt64(0), 3].contains(stop.uint(5) ?? 0),
                      let stopID = stop.string(4), !stopID.isEmpty else { continue }
                let arrival = try stop.messages(2).first?.uint(2)
                let departure = try stop.messages(3).first?.uint(2)
                guard let seconds = arrival ?? departure, seconds > 0, seconds <= UInt64(Int64.max) else { continue }
                predictions.append(Prediction(tripID: tripID, route: route, stopID: stopID,
                    time: Date(timeIntervalSince1970: TimeInterval(seconds)), direction: direction))
            }
        }
        return Feed(timestamp: Date(timeIntervalSince1970: TimeInterval(timestamp)), predictions: predictions)
    }
}

/// Service directions from NYCT TripDescriptor.direction, not geographic bearings.
enum MTADirection: String, CaseIterable, Sendable {
    case north = "N", south = "S", east = "E", west = "W", unknown = "?"
    init?(nyctValue: UInt64) {
        switch nyctValue {
        case 1: self = .north
        case 2: self = .east
        case 3: self = .south
        case 4: self = .west
        default: return nil
        }
    }
    var label: String {
        switch self {
        case .north: return "Northbound"
        case .south: return "Southbound"
        case .east: return "Eastbound"
        case .west: return "Westbound"
        case .unknown: return "Direction TBD"
        }
    }
    var opposite: Self {
        switch self {
        case .north: return .south
        case .south: return .north
        case .east: return .west
        case .west: return .east
        case .unknown: return .unknown
        }
    }
    static func resolve(_ prediction: MTAGTFSRealtime.Prediction, allowStopSuffix: Bool = true) -> Self {
        if let explicit = prediction.direction, explicit != .unknown { return explicit }
        guard allowStopSuffix else { return .unknown }
        return prediction.stopID.last.flatMap { Self(rawValue: String($0)) } ?? .unknown
    }
}
