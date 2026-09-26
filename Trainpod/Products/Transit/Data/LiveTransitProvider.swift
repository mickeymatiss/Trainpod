import Foundation

enum LiveTransitError: LocalizedError {
    case noDirections, payloadTooLarge, platformCapacityExceeded
    var errorDescription: String? {
        switch self {
        case .noDirections: return "No valid station data is currently available."
        case .platformCapacityExceeded: return "More platform directions than the device supports. View all directions in the app."
        case .payloadTooLarge: return "Live transit payload exceeds the device limit."
        }
    }
}

@MainActor
protocol TransitPayloadProvider {
    func currentPayload() async throws -> Data
}
