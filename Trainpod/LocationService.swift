import CoreLocation
import Foundation

enum LocationServiceError: LocalizedError {
    case denied
    case unavailable
    case alreadyRequesting

    var errorDescription: String? {
        switch self {
        case .denied: return "Location access is denied. Enable location access in Settings to find nearby CTA stations."
        case .unavailable: return "Could not get your current location."
        case .alreadyRequesting: return "A location request is already in progress."
        }
    }
}

@MainActor
final class LocationService: NSObject {
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocation, Error>?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func requestCurrentLocation() async throws -> CLLocation {
        guard continuation == nil else {
            throw LocationServiceError.alreadyRequesting
        }

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation

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
    }

    private func finish(with result: Result<CLLocation, Error>) {
        manager.stopUpdatingLocation()

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
                manager.requestLocation()
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
            guard let location = locations.last else {
                finish(with: .failure(LocationServiceError.unavailable))
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
