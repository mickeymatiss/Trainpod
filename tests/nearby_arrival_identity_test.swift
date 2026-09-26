import Foundation

@main struct NearbyArrivalIdentityChecks {
    static func main() {
        let now = Date(timeIntervalSince1970: 1000)
        func arrival(_ id: String, _ seconds: Double) -> CTAArrival {
            CTAArrival(id: id, route: "Blue", destination: "Terminal", arrivalTime: now.addingTimeInterval(seconds),
                       approaching: false, delayed: false, stationName: "Station", stopDescription: "North", directionID: "N")
        }
        let trains = [arrival("run-1", 270), arrival("run-2", 280)]
        let rows = trains.map { NearbyArrivalETA($0, at: now) }
        precondition(rows.map(\.minutes) == [5, 5])
        precondition(Set(rows.map(\.minutes)).count == 1, "Characterizes the former ETA-value identity collision")
        precondition(rows.map(\.id) == trains.map(\.id) && Set(rows.map(\.id)).count == 2)
        let later = trains.map { NearbyArrivalETA($0, at: now.addingTimeInterval(60)) }
        precondition(later.map(\.id) == rows.map(\.id) && later.map(\.minutes) == [4, 4])
        precondition(NearbyArrivalETA(arrival("past", -1), at: now).minutes == 0)
        precondition(NearbyArrivalETA(arrival("boundary", 60), at: now).minutes == 1)
        precondition(NearbyArrivalETA(arrival("after-boundary", 60.1), at: now).minutes == 2)
        print("PASS equal-ETA distinct arrival identity, unchanged order/rounding and stable IDs as minutes change")
    }
}
