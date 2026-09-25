import Foundation

nonisolated enum RealtimeTransitError: LocalizedError {
    case configuration, http(Int), invalidResponse, invalidSnapshot(String)
    var errorDescription: String? {
        switch self {
        case .configuration: return "Transit data HTTPS URL is not configured."
        case .http(let code): return "HTTP \(code)"
        case .invalidResponse: return "Invalid realtime HTTP response."
        case .invalidSnapshot(let reason): return "Invalid snapshot: \(reason)"
        }
    }
}

@MainActor
protocol RealtimeTransitFetching {
    func fetchSnapshot(systemId: TransitSystemID) async throws -> TransitRealtimeSnapshot
}

/// Shared normalized HTTP client; no provider, station selection, or BLE dependencies.
@MainActor
final class RealtimeTransitClient: RealtimeTransitFetching {
    private let baseURL: URL?
    private let session: URLSession

    init(baseURL: URL? = nil, session: URLSession? = nil) {
        self.baseURL = baseURL ?? TransitManifestClient.configuredBaseURL
        if let session { self.session = session }
        else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 10
            configuration.timeoutIntervalForResource = 15
            configuration.urlCache = nil
            self.session = URLSession(configuration: configuration)
        }
    }

    func snapshotURL(for systemId: TransitSystemID) throws -> URL {
        guard let baseURL, baseURL.scheme?.lowercased() == "https", baseURL.host != nil,
              baseURL.user == nil, baseURL.password == nil,
              baseURL.query == nil, baseURL.fragment == nil else { throw RealtimeTransitError.configuration }
        return baseURL.appendingPathComponent("systems", isDirectory: true)
            .appendingPathComponent(systemId.rawValue, isDirectory: true).appendingPathComponent("eta.json")
    }

    func fetchSnapshot(systemId: TransitSystemID) async throws -> TransitRealtimeSnapshot {
        var request = URLRequest(url: try snapshotURL(for: systemId),
                                 cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, http.url?.scheme == "https" else {
            throw RealtimeTransitError.invalidResponse
        }
        guard http.statusCode == 200 else { throw RealtimeTransitError.http(http.statusCode) }
        guard !data.isEmpty, data.count <= 8 * 1024 * 1024 else { throw RealtimeTransitError.invalidResponse }
        return try await Task.detached(priority: .utility) {
            try JSONDecoder().decode(TransitRealtimeSnapshot.self, from: data)
        }.value
    }
}
