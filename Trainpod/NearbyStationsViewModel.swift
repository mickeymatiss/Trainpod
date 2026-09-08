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

    private let locationService = LocationService()
    private let stationRepository = CTAStationRepository()
    private let transitCache = TransitDataCache.shared
    private var selectedStations: [CTAStation] = []
    private var refreshTask: Task<Void, Never>?
    private var isRefreshing = false

    func findNearbyTrains() {
        refreshTask?.cancel()
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
        if selectedStations.isEmpty {
            let stationArrivals = await loadNearbyStationsAndRefresh()
            if stationArrivals != nil {
                startRefreshLoop()
            }
            return stationArrivals
        }

        do {
            return try await refreshArrivals(showLoadingState: false)
        } catch {
            state = .error(error.localizedDescription)
            FileLogger.shared.log("[REFRESH] UI refresh failed code=\((error as NSError).code)")
            return nil
        }
    }

    private func loadNearbyStationsAndRefresh() async -> [StationArrivals]? {
        do {
            state = .requestingLocation
            let location = try await locationService.requestCurrentLocation()
            transitCache.rememberLocation(location)

            state = .loadingStationMetadata
            let stations = try await stationRepository.loadStations()
            selectedStations = nearestStations(to: location, from: stations)

            guard selectedStations.count >= 2 else {
                state = .error("Fewer than two valid CTA rail stations were found.")
                return nil
            }

            return try await refreshArrivals(showLoadingState: true)
        } catch is CancellationError {
            return nil
        } catch {
            state = .error(error.localizedDescription)
            FileLogger.shared.log("[REFRESH] Location or station loading failed code=\((error as NSError).code)")
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
                    _ = try await refreshArrivals(showLoadingState: false)
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
            if case .loaded(let stationArrivals, _) = state {
                return stationArrivals
            }
            return []
        }

        isRefreshing = true
        FileLogger.shared.log("[REFRESH] UI refresh started")
        defer { isRefreshing = false }

        if showLoadingState {
            state = .loadingArrivals
        }

        let cached = try await transitCache.result(for: selectedStations)
        let stationArrivals = cached.arrivals

        try Task.checkCancellation()
        state = .loaded(stationArrivals, updatedAt: cached.fetchedAt)
        FileLogger.shared.log(stationArrivals.isEmpty ? "[REFRESH] UI refresh failed" : "[REFRESH] UI refresh completed")
        return stationArrivals
    }

    private func nearestStations(to location: CLLocation, from stations: [CTAStation]) -> [CTAStation] {
        stations
            .sorted { left, right in
                left.location.distance(from: location) < right.location.distance(from: location)
            }
            .prefix(2)
            .map { station in station }
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
