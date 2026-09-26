import Foundation

// Host-only provider/environment doubles. The view model and transit models are
// compiled with ONLY its sleep expression replaced by RetryTestClock.sleep().
// The separate runner asserts one exact replacement; production stays unchanged.
enum TransitAgency: CaseIterable { case cta, mta, bart, mbta
    @MainActor static var selected: Self = .cta
}
struct LocationService {}
struct CTAStationRepository {}
struct FileLogger { static let shared = Self(); func log(_ text: String) {} }
struct LiveTransitFormatter { static func directionLabel(_ id: String) -> String { id } }
struct Sample { let stations: [StationArrivals]; let completedAt: Date }
enum OrdinaryFailure: Error { case unavailable }
@MainActor final class LiveTransitProvider {
    static var created: [LiveTransitProvider] = []
    var calls = 0
    var failCalls: Set<Int> = []
    var cancelCalls: Set<Int> = []
    var suspendNext = false
    var completion: CheckedContinuation<Void, Never>?
    init() { Self.created.append(self) }
    func currentArrivals() async throws -> Sample {
        calls += 1
        if suspendNext {
            suspendNext = false
            await withCheckedContinuation { completion = $0 }
        }
        if cancelCalls.contains(calls) { throw CancellationError() }
        if failCalls.contains(calls) { throw OrdinaryFailure.unavailable }
        let station = CTAStation(id: String(calls), name: "Fixture", latitude: 41, longitude: -87, mapID: "1", stopIDs: ["1"])
        let train = CTAArrival(id: String(calls), route: "Red", destination: "Fixture", arrivalTime: Date(timeIntervalSince1970: Double(calls + 300)), approaching: false, delayed: false, stationName: station.name, stopDescription: "North", directionID: "N")
        let direction = DirectionArrivals(id: "N", name: "North", trains: [train])
        return Sample(stations: [StationArrivals(station: station, directions: [direction])], completedAt: Date(timeIntervalSince1970: Double(calls)))
    }
}
@MainActor enum RetryTestClock {
    static var waiters: [CheckedContinuation<Void, Never>] = []
    static func sleep() async throws {
        await withCheckedContinuation { waiters.append($0) }
        try Task.checkCancellation()
    }
    static func advance() {
        let pending = waiters
        waiters = []
        for waiter in pending { waiter.resume() }
    }
    static func settle() async {
        for _ in 0..<100 { await Task.yield() }
    }
}
@main struct NearbyRetryPolicyTest {
    @MainActor static func main() async throws {
        for agency in TransitAgency.allCases {
            TransitAgency.selected = agency
            let model = NearbyStationsViewModel()
            let provider = LiveTransitProvider.created.last!
            provider.failCalls = [1, 2]
            model.findNearbyTrains()
            await RetryTestClock.settle()
            precondition(provider.calls == 1)
            guard case .error = model.state else { fatalError("Initial error remains visible") }
            precondition(RetryTestClock.waiters.count == 1, "Initial failure must leave one normal periodic attempt scheduled")
            await RetryTestClock.settle()
            precondition(provider.calls == 1, "No immediate retry")
            RetryTestClock.advance()
            await RetryTestClock.settle()
            precondition(provider.calls == 2 && RetryTestClock.waiters.count == 1)
            RetryTestClock.advance()
            await RetryTestClock.settle()
            precondition(provider.calls == 3)
            let successful = model.state
            guard case .loaded(let arrivals, let updatedAt) = successful else { fatalError("Initial recovery must load normally") }
            precondition(arrivals.first?.station.id == "3" && updatedAt == Date(timeIntervalSince1970: 3))
            provider.failCalls = [4, 5]
            for expected in 4...5 {
                RetryTestClock.advance()
                await RetryTestClock.settle()
                precondition(provider.calls == expected && model.state == successful, "Retain arrivals AND their original freshness timestamp")
                precondition(RetryTestClock.waiters.count == 1)
                await RetryTestClock.settle()
                precondition(provider.calls == expected, "Repeated failure waits for another cadence tick")
            }
            RetryTestClock.advance()
            await RetryTestClock.settle()
            guard case .loaded(let newer, let date) = model.state else { fatalError("Periodic recovery") }
            precondition(newer.first?.station.id == "6" && date == Date(timeIntervalSince1970: 6))
            // User-triggered refresh still executes immediately and owns one replacement loop.
            model.findNearbyTrains()
            await RetryTestClock.settle()
            precondition(provider.calls == 7)
            RetryTestClock.advance() // Includes the cancelled old sleeper; it must not fetch.
            await RetryTestClock.settle()
            precondition(provider.calls == 8 && RetryTestClock.waiters.count == 1)
            model.stopRefreshing() // Same hook as NearbyStationsView.onDisappear.
            RetryTestClock.advance()
            await RetryTestClock.settle()
            precondition(provider.calls == 8 && RetryTestClock.waiters.isEmpty)

            let active = NearbyStationsViewModel()
            let activeProvider = LiveTransitProvider.created.last!
            active.findNearbyTrains()
            await RetryTestClock.settle()
            let oldState = active.state
            activeProvider.suspendNext = true
            RetryTestClock.advance()
            await RetryTestClock.settle()
            precondition(activeProvider.completion != nil)
            active.stopRefreshing()
            activeProvider.completion?.resume(); activeProvider.completion = nil
            await RetryTestClock.settle()
            precondition(active.state == oldState && RetryTestClock.waiters.isEmpty)

            let invalidated = NearbyStationsViewModel()
            let invalidatedProvider = LiveTransitProvider.created.last!
            invalidatedProvider.cancelCalls = [2]
            invalidated.findNearbyTrains()
            await RetryTestClock.settle()
            RetryTestClock.advance()
            await RetryTestClock.settle()
            precondition(invalidatedProvider.calls == 2 && RetryTestClock.waiters.isEmpty, "Provider context cancellation stays terminal for the old periodic loop")
            invalidated.stopRefreshing()

            let cancelled = NearbyStationsViewModel()
            let pending = LiveTransitProvider.created.last!
            pending.suspendNext = true
            cancelled.findNearbyTrains()
            await RetryTestClock.settle()
            precondition(pending.completion != nil)
            cancelled.stopRefreshing()
            pending.completion?.resume(); pending.completion = nil
            await RetryTestClock.settle()
            precondition(pending.calls == 1 && RetryTestClock.waiters.isEmpty, "Cancelled initial work must not rearm the loop")
            guard case .loaded = cancelled.state else {
                print("PASS \(agency): initial/periodic recovery, retained data/date, cadence, manual refresh, teardown and in-flight cancellation")
                continue
            }
            fatalError("Cancelled fetch must not publish")
        }
    }
}
