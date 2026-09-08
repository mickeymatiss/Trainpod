import CoreLocation
import Foundation
import UIKit

enum LocationServiceError: LocalizedError {
    case denied
    case unavailable
    case alreadyRequesting
    case backgroundPermissionRequired

    var errorDescription: String? {
        switch self {
        case .denied: return "Location access is denied. Enable location access in Settings to find nearby CTA stations."
        case .unavailable: return "Could not get your current location."
        case .alreadyRequesting: return "A location request is already in progress."
        case .backgroundPermissionRequired: return "Open Nearby and enable Always location access before a locked-phone refresh."
        }
    }
}

@MainActor
final class LocationService: NSObject {
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocation, Error>?
    private var timeoutTask: Task<Void, Never>?
    private var requestedAt: Date?
    private var requestID: UUID?
    private var wantsAlwaysAuthorization = false

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.allowsBackgroundLocationUpdates = true
    }

    func enableBackgroundLocation() {
        guard UIApplication.shared.applicationState == .active else { return }
        if manager.authorizationStatus == .notDetermined {
            wantsAlwaysAuthorization = true
            manager.requestWhenInUseAuthorization()
        } else {
            manager.requestAlwaysAuthorization()
        }
    }

    func requestCurrentLocation() async throws -> CLLocation {
        guard continuation == nil else {
            throw LocationServiceError.alreadyRequesting
        }

        try Task.checkCancellation()
        if UIApplication.shared.applicationState == .background,
           manager.authorizationStatus != .authorizedAlways {
            throw LocationServiceError.backgroundPermissionRequired
        }
        let id = UUID()
        return try await withTaskCancellationHandler {
          try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            requestID = id
            requestedAt = Date()
            timeoutTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(8)) } catch { return }
                self?.finish(with: .failure(LocationServiceError.unavailable))
            }

            switch manager.authorizationStatus {
            case .notDetermined:
                manager.requestWhenInUseAuthorization()
            case .authorizedAlways, .authorizedWhenInUse:
                manager.requestLocation()
            case .denied, .restricted:
                finish(with: .failure(LocationServiceError.denied))
            @unknown default:
                finish(with: .failure(LocationServiceError.unavailable))
            }
          }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard self?.requestID == id else { return }
                self?.finish(with: .failure(CancellationError()))
            }
        }
    }

    /// A recent known context allows a cache hit without waiting for another GPS fix.
    var recentLocation: CLLocation? {
        guard let fix = manager.location, fix.horizontalAccuracy >= 0,
              fix.horizontalAccuracy <= 1000,
              (0..<TransitDataCache.freshnessInterval).contains(-fix.timestamp.timeIntervalSinceNow) else { return nil }
        return fix
    }

    private func finish(with result: Result<CLLocation, Error>) {
        manager.stopUpdatingLocation()
        timeoutTask?.cancel()
        timeoutTask = nil
        requestedAt = nil
        requestID = nil

        guard let continuation else {
            return
        }

        self.continuation = nil

        switch result {
        case .success(let location):
            continuation.resume(returning: location)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }
}

extension LocationService: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            switch manager.authorizationStatus {
            case .authorizedAlways, .authorizedWhenInUse:
                if wantsAlwaysAuthorization && manager.authorizationStatus == .authorizedWhenInUse {
                    wantsAlwaysAuthorization = false
                    manager.requestAlwaysAuthorization()
                }
                if continuation != nil { manager.requestLocation() }
            case .denied, .restricted:
                finish(with: .failure(LocationServiceError.denied))
            case .notDetermined:
                break
            @unknown default:
                finish(with: .failure(LocationServiceError.unavailable))
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in
            guard let requestedAt,
                  let location = locations.last(where: {
                      $0.horizontalAccuracy >= 0 && $0.horizontalAccuracy <= 1000 &&
                      $0.timestamp >= requestedAt.addingTimeInterval(-5)
                  }) else {
                // requestLocation may initially return a cached fix; wait for a fresh one.
                if continuation != nil { manager.requestLocation() }
                return
            }

            finish(with: .success(location))
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            finish(with: .failure(error))
        }
    }
}
