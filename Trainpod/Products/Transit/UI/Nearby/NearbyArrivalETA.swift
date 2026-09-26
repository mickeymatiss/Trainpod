import Foundation

/// Keep the arrival's identity when projecting it to the displayed minute value.
struct NearbyArrivalETA: Identifiable, Equatable {
    let id: String
    let minutes: Int

    init(_ arrival: CTAArrival, at date: Date = Date()) {
        id = arrival.id
        minutes = max(0, Int((arrival.arrivalTime.timeIntervalSince(date) / 60).rounded(.up)))
    }
}
