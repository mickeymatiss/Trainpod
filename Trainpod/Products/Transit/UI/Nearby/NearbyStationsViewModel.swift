import Combine
import CoreLocation
import Foundation

@MainActor
final class NearbyStationsViewModel: ObservableObject {
    enum ViewState: Equatable {
        case idle
        case requestingLocation
        case loadingStationMetadata
        case loadingArrivals
        case loaded([StationArrivals], updatedAt: Date)
        case error(String)
    }

    @Published private(set) var state: ViewState = .idle

    private let servingProvider = LiveTransitProvider()
    private let locationService = LocationService()
    private let stationRepository = CTAStationRepository()
    private let transitCache = TransitDataCache.shared
    private var selectedStations: [CTAStation] = []
    private var refreshTask: Task<Void, Never>?
    private var isRefreshing = false
    private var agency = TransitAgency.selected

    func findNearbyTrains() {
        refreshTask?.cancel()
        agency = TransitAgency.selected
        selectedStations = []
        refreshTask = Task {
            guard await loadNearbyStationsAndRefresh() != nil else {
                return
            }

            startRefreshLoop()
        }
    }

    func stopRefreshing() {
        refreshTask?.cancel()
        refreshTask = nil
        isRefreshing = false
    }

    func freshArrivalsForBLESend() async -> [StationArrivals]? {
        if agency == .mta || agency != TransitAgency.selected || selectedStations.isEmpty {
            agency = TransitAgency.selected
            let stationArrivals = await loadNearbyStationsAndRefresh()
            if stationArrivals != nil {
                startRefreshLoop()
            }
            return stationArrivals
        }

        do {
            return try await refreshArrivals(showLoadingState: false)
        } catch {
            guard !Task.isCancelled else { return nil }
            state = .error(error.localizedDescription)
            FileLogger.shared.log("[REFRESH] UI refresh failed code=\((error as NSError).code)")
            return nil
        }
    }

    private func loadNearbyStationsAndRefresh() async -> [StationArrivals]? {
        state = .requestingLocation
        do { return try await refreshArrivals(showLoadingState: true) }
        catch {
            guard !Task.isCancelled else { return nil }
            state = .error(error.localizedDescription)
            return nil
        }
    }

    private func startRefreshLoop() {
        refreshTask?.cancel()
        refreshTask = Task {
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(60))
                    try Task.checkCancellation()
                    if agency == .mta {
                        _ = await loadNearbyStationsAndRefresh()
                    } else {
                        _ = try await refreshArrivals(showLoadingState: false)
                    }
                } catch is CancellationError {
                    return
                } catch {
                    state = .error(error.localizedDescription)
                    return
                }
            }
        }
    }

    private func refreshArrivals(showLoadingState: Bool) async throws -> [StationArrivals] {
        guard !isRefreshing else {
            if case .loaded(let arrivals, _) = state { return arrivals }
            return []
        }
        isRefreshing = true
        defer { isRefreshing = false }
        if showLoadingState { state = .loadingArrivals }
        let result = try await servingProvider.currentArrivals()
        try Task.checkCancellation()
        selectedStations = result.stations.map(\.station)
        state = .loaded(result.stations, updatedAt: result.completedAt)
        return result.stations
    }

    private func nearestStations(to location: CLLocation, from stations: [CTAStation]) -> [CTAStation] {
        stations
            .filter(\.isRealtimeCandidate)
            .sorted { left, right in
                let leftDistance = left.location.distance(from: location)
                let rightDistance = right.location.distance(from: location)
                return leftDistance == rightDistance ? left.mapID < right.mapID : leftDistance < rightDistance
            }
    }

    static func groupArrivals(_ arrivals: [CTAArrival], for station: CTAStation) -> StationArrivals {
        var grouped = Dictionary(grouping: arrivals) { arrival in arrival.directionID }
        // Preserve empty platforms, including stations with no current arrivals.
        for direction in station.stopDirections?.values ?? Dictionary<String, String>().values {
            if grouped[direction] == nil { grouped[direction] = [] }
        }

        let unsortedDirections: [DirectionArrivals] = grouped.map { directionID, trains in
            let sortedTrains = trains.sorted { left, right in
                left.arrivalTime < right.arrivalTime
            }
            let name = LiveTransitFormatter.directionLabel(directionID)

            return DirectionArrivals(
                id: directionID,
                name: name,
                trains: Array(sortedTrains.prefix(9))
            )
        }

        let sortedDirections = unsortedDirections.sorted { left, right in
            left.name.localizedStandardCompare(right.name) == .orderedAscending
        }

        return StationArrivals(station: station, directions: sortedDirections)
    }
}
