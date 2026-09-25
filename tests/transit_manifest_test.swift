import Foundation
import Combine

// Standalone harness shims for the app's existing selection/logger dependencies.
enum TransitAgency { case cta, mta }
final class FileLogger {
    static let shared = FileLogger()
    func log(_ message: String) {}
}

@MainActor
final class FakeClient: TransitManifestFetching {
    var results: [TransitSystemID: ManifestFetchResult] = [:]
    var requests: [(TransitSystemID, String?)] = []
    var failure = false
    var paused = false
    var pending: [TransitSystemID: CheckedContinuation<ManifestFetchResult, Error>] = [:]
    func fetch(systemID: TransitSystemID, etag: String?) async throws -> ManifestFetchResult {
        requests.append((systemID, etag))
        if failure { throw URLError(.notConnectedToInternet) }
        if paused {
            return try await withCheckedThrowingContinuation { pending[systemID] = $0 }
        }
        return results[systemID]!
    }
}

nonisolated final class FailingCache: TransitManifestCaching {
    let entry: CachedTransitManifest
    init(_ entry: CachedTransitManifest) { self.entry = entry }
    func read(for systemID: TransitSystemID) throws -> CachedTransitManifest? { entry }
    func write(_ entry: CachedTransitManifest, for systemID: TransitSystemID) throws {
        throw CocoaError(.fileWriteOutOfSpace)
    }
}

final class MockHTTP: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var payload = Data()
    nonisolated(unsafe) static var lastRequest: URLRequest?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lastRequest = request
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status,
            httpVersion: "HTTP/1.1", headerFields: ["ETag": "\"server-tag\""])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.payload)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

extension TransitManifestManager {
    func loadForCheck(systemId: TransitSystemID) async {
        activate(systemId: systemId)
        await refreshIfChanged(systemId: systemId)
    }
}

@main
struct ManifestChecks {
    @MainActor static func main() async throws {
        let paths = Array(CommandLine.arguments.dropFirst())
        let nycData = try Data(contentsOf: URL(fileURLWithPath: paths[0]))
        let ctaData = try Data(contentsOf: URL(fileURLWithPath: paths[1]))
        let decoder = JSONDecoder()
        let nyc = try decoder.decode(TransitSystemManifest.self, from: nycData)
        let cta = try decoder.decode(TransitSystemManifest.self, from: ctaData)
        try TransitManifestValidator.validate(nyc, expectedSystemID: .nyc)
        try TransitManifestValidator.validate(cta, expectedSystemID: .cta)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = TransitManifestCache(directory: directory)
        let client = FakeClient()
        client.results = [.nyc: .updated(data: nycData, etag: "\"nyc1\""),
                          .cta: .updated(data: ctaData, etag: "\"cta1\"")]
        let manager = TransitManifestManager(client: client, cache: cache, log: { _ in })
        await manager.loadForCheck(systemId: .nyc)
        assert(manager.currentManifest == nyc && manager.lastError == nil)
        await manager.loadForCheck(systemId: .cta)
        assert(manager.currentManifest == cta)
        let savedNYC = try cache.read(for: .nyc)
        assert(savedNYC?.etag == "\"nyc1\"")
        client.results[.nyc] = .notModified
        await manager.loadForCheck(systemId: .nyc)
        assert(client.requests.last?.1 == "\"nyc1\"" && manager.currentManifest == nyc)
        var publications = 0
        let subscription = manager.objectWillChange.sink { publications += 1 }
        await manager.refreshIfChanged(systemId: .nyc)
        assert(publications == 0, "304 must not invalidate app state")
        client.failure = true
        await manager.refreshIfChanged(systemId: .nyc)
        assert(publications == 0, "Background failure must not invalidate app state")
        subscription.cancel()
        let restart = TransitManifestManager(client: client, cache: TransitManifestCache(directory: directory), log: { _ in })
        await restart.loadForCheck(systemId: .cta)
        assert(restart.currentManifest == cta && restart.lastError != nil)
        client.failure = false
        client.results[.cta] = .updated(data: nycData, etag: "bad")
        await restart.refreshIfChanged(systemId: .cta)
        assert(restart.currentManifest == cta && restart.lastError != nil)
        let savedCTA = try cache.read(for: .cta)
        assert(savedCTA?.etag == "\"cta1\"")
        client.results[.cta] = .updated(data: ctaData, etag: "cta2")
        let diskFailure = TransitManifestManager(client: client,
            cache: FailingCache(CachedTransitManifest(manifest: cta, etag: "old")), log: { _ in })
        await diskFailure.loadForCheck(systemId: .cta)
        assert(diskFailure.currentManifest == cta && diskFailure.lastError != nil)
        await diskFailure.refreshIfChanged(systemId: .cta)
        assert(client.requests.last?.1 == "old")
        // New city is exposed from disk while its refresh is still suspended.
        client.paused = true
        manager.activate(systemId: .nyc)
        assert(manager.currentManifest == nyc, "Activation exposes cached data synchronously")
        let oldLoad = Task { await manager.refreshIfChanged(systemId: .nyc) }
        while client.pending[.nyc] == nil { await Task.yield() }
        manager.activate(systemId: .cta)
        assert(manager.currentManifest == cta, "Activation must return while HTTP is suspended")
        let newLoad = Task { await manager.refreshIfChanged(systemId: .cta) }
        while client.pending[.cta] == nil { await Task.yield() }
        assert(manager.currentManifest == cta && manager.isRefreshing)
        client.pending.removeValue(forKey: .cta)!.resume(returning: .notModified)
        await newLoad.value
        client.pending.removeValue(forKey: .nyc)!.resume(returning: .updated(data: nycData, etag: "nyc2"))
        await oldLoad.value
        assert(manager.currentManifest == cta && !manager.isRefreshing)
        let builder = TransitManifestClient(baseURL: URL(string: "https://example.com"))
        let ctaURL = try builder.manifestURL(for: .cta)
        assert(ctaURL.absoluteString == "https://example.com/systems/cta/system.json")
        let nycURL = try builder.manifestURL(for: .nyc)
        assert(nycURL.absoluteString == "https://example.com/systems/nyc/system.json")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockHTTP.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let http = TransitManifestClient(baseURL: URL(string: "https://example.com"), session: session)
        MockHTTP.payload = ctaData
        let downloaded = try await http.fetch(systemID: .cta, etag: "saved-tag")
        guard case .updated(let bytes, let tag) = downloaded else { fatalError("Expected HTTP 200") }
        assert(bytes == ctaData && tag != nil)
        assert(MockHTTP.lastRequest?.value(forHTTPHeaderField: "If-None-Match") == "saved-tag")
        assert(MockHTTP.lastRequest?.url?.path == "/systems/cta/system.json")
        MockHTTP.status = 304
        guard case .notModified = try await http.fetch(systemID: .nyc, etag: "nyc-tag") else {
            fatalError("Expected HTTP 304")
        }
        MockHTTP.status = 503
        do { _ = try await http.fetch(systemID: .nyc, etag: nil); fatalError("Accepted HTTP 503") }
        catch TransitManifestError.httpStatus(503) {}
        print("Passed: both real manifests, isolated caches/ETags, 304, offline restart, invalid replacement, failed disk write, city-switch race, immediate activation, silent 304/failure, and HTTP behavior.")
    }
}
