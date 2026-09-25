import Foundation

/// One atomic record binds a manifest to its ETag even across crashes or interrupted writes.
nonisolated struct CachedTransitManifest: Codable, Sendable {
    let manifest: TransitSystemManifest
    let etag: String?
}

nonisolated protocol TransitManifestCaching: Sendable {
    func read(for systemID: TransitSystemID) throws -> CachedTransitManifest?
    func write(_ entry: CachedTransitManifest, for systemID: TransitSystemID) throws
}

nonisolated final class TransitManifestCache: TransitManifestCaching {
    private let directory: URL

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TransitManifests", isDirectory: true)
    }

    private func fileURL(for systemID: TransitSystemID) -> URL {
        directory.appendingPathComponent(systemID.rawValue, isDirectory: true)
            .appendingPathComponent("system.json")
    }

    func read(for systemID: TransitSystemID) throws -> CachedTransitManifest? {
        let url = fileURL(for: systemID)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let entry = try JSONDecoder().decode(CachedTransitManifest.self, from: Data(contentsOf: url))
        try TransitManifestValidator.validate(entry.manifest, expectedSystemID: systemID)
        return entry
    }

    func write(_ entry: CachedTransitManifest, for systemID: TransitSystemID) throws {
        try TransitManifestValidator.validate(entry.manifest, expectedSystemID: systemID)
        let data = try JSONEncoder().encode(entry)
        let url = fileURL(for: systemID)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
