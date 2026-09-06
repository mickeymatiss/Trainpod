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
    private let ctaClient = CTAClient()
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
            return nil
        }
    }

    private func loadNearbyStationsAndRefresh() async -> [StationArrivals]? {
        do {
            state = .requestingLocation
            let location = try await locationService.requestCurrentLocation()

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
        defer { isRefreshing = false }

        if showLoadingState {
            state = .loadingArrivals
        }

        var stationArrivals: [StationArrivals] = []
        for station in selectedStations {
            let arrivals = try await ctaClient.fetchArrivals(for: station)
            stationArrivals.append(Self.groupArrivals(arrivals, for: station))
        }

        state = .loaded(stationArrivals, updatedAt: Date())
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

    private static func groupArrivals(_ arrivals: [CTAArrival], for station: CTAStation) -> StationArrivals {
        let grouped = Dictionary(grouping: arrivals) { arrival in arrival.directionID }

        let unsortedDirections: [DirectionArrivals] = grouped.map { directionID, trains in
            let sortedTrains = trains.sorted { left, right in
                left.arrivalTime < right.arrivalTime
            }
            let name = sortedTrains.first?.directionName ?? "Direction \(directionID)"

            return DirectionArrivals(
                id: directionID,
                name: name,
                trains: Array(sortedTrains.prefix(3))
            )
        }

        let sortedDirections = unsortedDirections.sorted { left, right in
            left.name.localizedStandardCompare(right.name) == .orderedAscending
        }

        return StationArrivals(station: station, directions: sortedDirections)
    }
}
