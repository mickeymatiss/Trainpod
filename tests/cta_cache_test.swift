import Foundation

final class MetadataFiles: FileManager, @unchecked Sendable {
    let directory: URL
    var failSave = false
    init(_ directory: URL) { self.directory = directory; super.init() }
    override func url(for directory: SearchPathDirectory, in domain: SearchPathDomainMask,
                      appropriateFor url: URL?, create shouldCreate: Bool) throws -> URL { self.directory }
    override func createDirectory(at url: URL, withIntermediateDirectories create: Bool,
                                  attributes: [FileAttributeKey: Any]? = nil) throws {
        if failSave { throw CocoaError(.fileWriteOutOfSpace) }
        try super.createDirectory(at: url, withIntermediateDirectories: create, attributes: attributes)
    }
}
final class MetadataHTTP: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requests = 0
    nonisolated(unsafe) static var fail = false
    static let fixture = Data(#"[{"stop_id":"30001","direction_id":"N","station_name":"Fixture","map_id":"40001","location":{"latitude":"41.9","longitude":"-87.6"}},{"stop_id":"30002","direction_id":"S","station_name":"Fixture","map_id":"40001","location":{"latitude":"41.9","longitude":"-87.6"}}]"#.utf8)
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests += 1
        if Self.fail { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)); return }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.fixture)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main struct CTACacheChecks {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = MetadataFiles(root)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MetadataHTTP.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let repository = CTAStationRepository(fileManager: files, session: session)
        let cache = root.appendingPathComponent("CTAStationMetadata/stations.json")
        let expected = CTAStation(id: "40001", name: "Fixture", latitude: 41.9, longitude: -87.6,
                                  mapID: "40001", stopIDs: ["30001", "30002"], stopDirections: ["30001":"N", "30002":"S"])
        var failures: [String] = []
        func load(_ name: String) async {
            do { let values = try await repository.loadStations(); if values != [expected] { failures.append(name + ": wrong metadata") } }
            catch { failures.append(name + ": \(error)") }
        }
        await load("missing cache + network + save")
        precondition(MetadataHTTP.requests == 1 && FileManager.default.fileExists(atPath: cache.path))
        let saved = try JSONDecoder().decode([CTAStation].self, from: Data(contentsOf: cache))
        precondition(saved == [expected])
        MetadataHTTP.fail = true
        await load("usable cache while upstream is unavailable")
        precondition(MetadataHTTP.requests == 1, "Valid cache is authoritative: no network attempted")
        MetadataHTTP.fail = false
        try Data("{truncated".utf8).write(to: cache)
        await load("corrupt cache recovers by fetching")
        if MetadataHTTP.requests != 2 { failures.append("Corrupt cache blocked the network") }
        try? FileManager.default.removeItem(at: cache)
        files.failSave = true
        await load("network success survives storage failure")
        precondition(!FileManager.default.fileExists(atPath: cache.path))
        files.failSave = false
        // Old metadata missing required direction mapping must NOT become a usable
        // fallback merely because a download failed; preserve existing semantics.
        var old = expected; old.stopDirections = nil
        try JSONEncoder().encode([old]).write(to: cache)
        MetadataHTTP.fail = true
        do { _ = try await repository.loadStations(); failures.append("Accepted cache without required mapping") }
        catch { }
        try Data("{truncated".utf8).write(to: cache)
        do { _ = try await repository.loadStations(); failures.append("Invented metadata with corrupt cache + failed network") }
        catch { }
        precondition(failures.isEmpty, failures.joined(separator: "\n"))
        print("PASS CTA valid/missing/corrupt cache, save failure, upstream outage, mandatory direction mapping")
    }
}
