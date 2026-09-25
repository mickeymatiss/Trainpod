import Combine
import Foundation

@MainActor
final class TransitManifestManager: ObservableObject {
    static let shared = TransitManifestManager()
    @Published private(set) var currentManifest: TransitSystemManifest?
    @Published private(set) var currentSystemID: TransitSystemID?
    // Diagnostics only: background maintenance must not invalidate UI state.
    private(set) var isRefreshing = false
    private(set) var lastError: String?

    private let client: any TransitManifestFetching
    private let cache: any TransitManifestCaching
    private let log: (String) -> Void
    private var entries: [TransitSystemID: CachedTransitManifest] = [:]
    private var inFlight: [TransitSystemID: Task<Void, Never>] = [:]

    init(client: (any TransitManifestFetching)? = nil,
         cache: (any TransitManifestCaching)? = nil,
         log: @escaping (String) -> Void = { FileLogger.shared.log($0) }) {
        self.client = client ?? TransitManifestClient(baseURL: TransitManifestClient.configuredBaseURL)
        self.cache = cache ?? TransitManifestCache()
        self.log = log
    }

    func cachedManifest(for systemID: TransitSystemID) -> TransitSystemManifest? {
        if let entry = entries[systemID] { return entry.manifest }
        do {
            if let entry = try cache.read(for: systemID) {
                entries[systemID] = entry
                record("manifest_cache_hit", systemID)
                return entry.manifest
            }
        } catch {
            record("manifest_validation_failed", systemID)
            // Invalid/missing cache never supplies an ETag to a conditional request.
        }
        record("manifest_cache_miss", systemID)
        return nil
    }

    /// Local data is available before returning. Network work is never awaited here.
    func activate(systemId: TransitSystemID) {
        record("manifest_load_started", systemId)
        if currentSystemID != systemId {
            record("manifest_system_changed", systemId)
            currentSystemID = systemId
        }
        let manifest = cachedManifest(for: systemId)
        if currentManifest != manifest { currentManifest = manifest }
        lastError = nil
        isRefreshing = true
        _ = startRefresh(systemID: systemId)
    }

    /// Awaitable for internal coordination; UX callers use activate(systemId:).
    func refreshIfChanged(systemId: TransitSystemID) async {
        await startRefresh(systemID: systemId).value
    }

    private func startRefresh(systemID: TransitSystemID) -> Task<Void, Never> {
        if let task = inFlight[systemID] { return task }
        _ = cachedManifest(for: systemID)
        if currentSystemID == systemID { isRefreshing = true }
        // The task belongs to the manager, not the view. Switching cities can finish
        // caching the old response without changing the newly active city's state.
        let task = Task(priority: .utility) {
            await self.refresh(systemID: systemID)
            self.inFlight[systemID] = nil
        }
        inFlight[systemID] = task
        return task
    }

    private func refresh(systemID: TransitSystemID) async {
        record("manifest_refresh_started", systemID)
        defer { if currentSystemID == systemID { isRefreshing = false } }
        do {
            var result = try await client.fetch(systemID: systemID, etag: entries[systemID]?.etag)
            if case .notModified = result, entries[systemID] == nil {
                result = try await client.fetch(systemID: systemID, etag: nil)
            }
            switch result {
            case .notModified:
                guard entries[systemID] != nil else { throw TransitManifestError.missingCache }
                record("manifest_not_modified", systemID)
            case .updated(let data, let etag):
                let cache = self.cache
                let entry = try await Task.detached(priority: .utility) {
                    let candidate = try JSONDecoder().decode(TransitSystemManifest.self, from: data)
                    try TransitManifestValidator.validate(candidate, expectedSystemID: systemID)
                    let entry = CachedTransitManifest(manifest: candidate, etag: etag)
                    try cache.write(entry, for: systemID)
                    return entry
                }.value
                entries[systemID] = entry
                record("manifest_updated", systemID,
                       "stations=\(entry.manifest.stations.count) routes=\(entry.manifest.routes.count)")
                if currentSystemID == systemID && currentManifest != entry.manifest {
                    currentManifest = entry.manifest
                }
            }
            // A 304 never rewrites the cache or publishes an unchanged manifest.
            if currentSystemID == systemID { lastError = nil }
        } catch {
            if error is DecodingError { record("manifest_validation_failed", systemID) }
            if case TransitManifestError.invalidManifest = error {
                record("manifest_validation_failed", systemID)
            }
            if currentSystemID == systemID { lastError = error.localizedDescription }
            record("manifest_refresh_failed", systemID, "code=\((error as NSError).code)")
        }
    }

    private func record(_ event: String, _ systemID: TransitSystemID, _ detail: String = "") {
        log("[MANIFEST] \(event) systemId=\(systemID.rawValue) \(detail)")
    }
}
