import Foundation

/// Stable backend identifiers; the existing agency preference remains the selection source.
nonisolated enum TransitSystemID: String, Codable, Sendable {
    case nyc
    case cta
    case bart
    case mbta

    var supportsLegacySource: Bool { self == .cta || self == .nyc }

    var agency: TransitAgency {
        switch self {
        case .cta: return .cta
        case .nyc: return .mta
        case .bart: return .bart
        case .mbta: return .mbta
        }
    }
}

extension TransitAgency {
    var cityName: String {
        switch self {
        case .cta: return "Chicago"
        case .mta: return "New York"
        case .bart: return "Bay Area"
        case .mbta: return "Boston"
        }
    }

    var systemID: TransitSystemID {
        switch self {
        case .mta: return .nyc
        case .cta: return .cta
        case .bart: return .bart
        case .mbta: return .mbta
        }
    }
}
