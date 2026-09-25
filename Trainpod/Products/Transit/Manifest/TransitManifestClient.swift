import Foundation

nonisolated enum ManifestFetchResult: Sendable {
    case notModified
    case updated(data: Data, etag: String?)
}

@MainActor
protocol TransitManifestFetching {
    func fetch(systemID: TransitSystemID, etag: String?) async throws -> ManifestFetchResult
}

/// HTTP only. Disk caching and active-system state belong to the manager.
@MainActor
final class TransitManifestClient: TransitManifestFetching {
    private let baseURL: URL?
    private let session: URLSession

    init(baseURL: URL?, session: URLSession? = nil) {
        self.baseURL = baseURL
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 20
            configuration.timeoutIntervalForResource = 30
            configuration.urlCache = nil
            self.session = URLSession(configuration: configuration)
        }
    }

    static var configuredBaseURL: URL? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "TransitManifestBaseURL") as? String,
              !value.isEmpty else { return nil }
        return URL(string: value)
    }

    func manifestURL(for systemID: TransitSystemID) throws -> URL {
        guard let baseURL, baseURL.scheme?.lowercased() == "https", baseURL.host != nil,
              baseURL.user == nil, baseURL.password == nil,
              baseURL.query == nil, baseURL.fragment == nil else {
            throw TransitManifestError.configuration
        }
        return baseURL.appendingPathComponent("systems", isDirectory: true)
            .appendingPathComponent(systemID.rawValue, isDirectory: true)
            .appendingPathComponent("system.json")
    }

    func fetch(systemID: TransitSystemID, etag: String?) async throws -> ManifestFetchResult {
        var request = URLRequest(url: try manifestURL(for: systemID),
                                 cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse,
              response.url?.scheme?.lowercased() == "https" else {
            throw TransitManifestError.invalidResponse
        }
        switch response.statusCode {
        case 304: return .notModified
        case 200:
            guard !data.isEmpty, data.count <= 8 * 1024 * 1024 else {
                throw TransitManifestError.invalidResponse
            }
            return .updated(data: data, etag: response.value(forHTTPHeaderField: "ETag"))
        default: throw TransitManifestError.httpStatus(response.statusCode)
        }
    }
}
