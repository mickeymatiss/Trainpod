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
        do {
            state = .requestingLocation
            let mtaLocationMode = MTALocationMode.selected
            let location: CLLocation
            if agency == .mta, let testLocation = mtaLocationMode.locationOverride {
                location = testLocation
            } else {
                location = try await locationService.requestCurrentLocation()
                try Task.checkCancellation()
                transitCache.rememberLocation(location)
            }

            state = .loadingStationMetadata
            if agency == .mta {
                let stations = try await MTAStationRepository.shared.nearest(to: location)
                state = .loadingArrivals
                let nearby = try await MTAClient.shared.arrivals(for: stations)
                try Task.checkCancellation()
                guard TransitAgency.selected == .mta, MTALocationMode.selected == mtaLocationMode else { throw CancellationError() }
                state = .loaded(nearby, updatedAt: Date())
                return nearby
            }
            let stations = try await stationRepository.loadStations()
            try Task.checkCancellation()
            selectedStations = nearestStations(to: location, from: stations)

            guard selectedStations.count >= 2 else {
                state = .error("Fewer than two valid CTA rail stations were found.")
                return nil
            }

            return try await refreshArrivals(showLoadingState: true)
        } catch is CancellationError {
            return nil
        } catch {
            guard !Task.isCancelled else { return nil }
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
        guard TransitAgency.selected == .cta else { throw CancellationError() }
        state = .loaded(stationArrivals, updatedAt: cached.fetchedAt)
        FileLogger.shared.log(stationArrivals.isEmpty ? "[REFRESH] UI refresh failed" : "[REFRESH] UI refresh completed")
        return stationArrivals
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
