import Foundation

// Host-only provider/environment doubles. The view model and transit models are
// compiled with ONLY its sleep expression replaced by RetryTestClock.sleep().
// The separate runner asserts one exact replacement; production stays unchanged.
enum TransitAgency: CaseIterable { case cta, mta, bart, mbta
    @MainActor static var selected: Self = .cta
}
struct LocationService {}
struct CTAStationRepository {}
struct TransitDataCache { static let shared = Self() }
struct FileLogger { static let shared = Self(); func log(_ text: String) {} }
struct LiveTransitFormatter { static func directionLabel(_ id: String) -> String { id } }
struct Sample { let stations: [StationArrivals] = []; let completedAt = Date() }
enum OrdinaryFailure: Error { case unavailable }
@MainActor final class LiveTransitProvider {
    static var created: [LiveTransitProvider] = []
    var calls = 0
    var failFirst = false
    init() { Self.created.append(self) }
    func currentArrivals() async throws -> Sample {
        calls += 1
        if failFirst || calls == 2 { throw OrdinaryFailure.unavailable }
        return Sample()
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
        var periodic: [(TransitAgency, NearbyStationsViewModel, LiveTransitProvider)] = []
        var initial: [(NearbyStationsViewModel, LiveTransitProvider)] = []
        for agency in TransitAgency.allCases {
            TransitAgency.selected = agency
            let model = NearbyStationsViewModel()
            let provider = LiveTransitProvider.created.last!
            model.findNearbyTrains()
            periodic.append((agency, model, provider))
            // findNearbyTrains captures agency synchronously.
            let failed = NearbyStationsViewModel()
            let failedProvider = LiveTransitProvider.created.last!
            failedProvider.failFirst = true
            failed.findNearbyTrains()
            initial.append((failed, failedProvider))
        }
        TransitAgency.selected = .mta
        let cancelled = NearbyStationsViewModel()
        let cancelledProvider = LiveTransitProvider.created.last!
        cancelled.findNearbyTrains()
        await RetryTestClock.settle()
        cancelled.stopRefreshing()
        precondition(periodic.allSatisfy { $0.2.calls == 1 })
        precondition(initial.allSatisfy { $0.1.calls == 1 })
        precondition(RetryTestClock.waiters.count == 5)
        RetryTestClock.advance()
        await RetryTestClock.settle()
        for (agency, model, provider) in periodic {
            precondition(provider.calls == 2, "agency=\(agency) calls=\(provider.calls) state=\(model.state)")
            guard case .error = model.state else { fatalError("ordinary error must be visible") }
        }
        RetryTestClock.advance()
        await RetryTestClock.settle()
        for (agency, model, provider) in periodic {
            precondition(provider.calls == (agency == .mta ? 3 : 2))
            if agency == .mta {
                guard case .loaded = model.state else { fatalError("MTA must recover") }
            } else {
                guard case .error = model.state else { fatalError("non-MTA loop stops") }
            }
            model.stopRefreshing()
        }
        precondition(initial.allSatisfy { $0.1.calls == 1 })
        precondition(cancelledProvider.calls == 1)
        RetryTestClock.advance()
        await RetryTestClock.settle()
        print("PASS: current retry policy — initial errors stop all; periodic MTA recovers; CTA/BART/MBTA stop; cancellation stops.")
    }
}
