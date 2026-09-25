import Combine
import CoreBluetooth
import CoreLocation
import SwiftUI
import UIKit

/// Permission observation only. Never starts location updates, scans, or connections.
@MainActor
final class PermissionSetupState: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = PermissionSetupState()
    private let location = CLLocationManager()
    private var lastLoggedState: String?
    @Published private(set) var locationAuthorization: CLAuthorizationStatus = .notDetermined
    @Published private(set) var preciseLocation = false
    @Published private(set) var bluetoothAuthorization: CBManagerAuthorization = .notDetermined
    @Published private(set) var backgroundRefresh: UIBackgroundRefreshStatus = .restricted
    @Published private(set) var lowPowerMode = false

    override init() {
        super.init()
        location.delegate = self
        for name in [UIApplication.didBecomeActiveNotification,
                     UIApplication.backgroundRefreshStatusDidChangeNotification,
                     Notification.Name.NSProcessInfoPowerStateDidChange] {
            NotificationCenter.default.addObserver(self, selector: #selector(refreshFromNotification), name: name, object: nil)
        }
        refresh()
    }

    deinit { NotificationCenter.default.removeObserver(self) }
    @objc private func refreshFromNotification() { refresh() }

    var requiredPermissionsGranted: Bool {
        locationAuthorization == .authorizedAlways && bluetoothAuthorization == .allowedAlways
    }
    var needsSetup: Bool { !requiredPermissionsGranted }
    var backgroundReady: Bool {
        requiredPermissionsGranted && backgroundRefresh == .available && !lowPowerMode
    }

    func refresh() {
        locationAuthorization = location.authorizationStatus
        preciseLocation = location.accuracyAuthorization == .fullAccuracy
        bluetoothAuthorization = CBManager.authorization
        backgroundRefresh = UIApplication.shared.backgroundRefreshStatus
        lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        let snapshot = "location=\(locationAuthorization.rawValue) precise=\(preciseLocation) bluetooth=\(bluetoothAuthorization.rawValue) backgroundRefresh=\(backgroundRefresh.rawValue) lowPower=\(lowPowerMode)"
        if snapshot != lastLoggedState {
            lastLoggedState = snapshot
            FileLogger.shared.log("[PERMISSIONS] " + snapshot)
        }
    }

    func requestLocation() {
        guard UIApplication.shared.applicationState == .active else { return }
        switch location.authorizationStatus {
        case .notDetermined: location.requestWhenInUseAuthorization()
        case .authorizedWhenInUse: location.requestAlwaysAuthorization()
        case .denied, .restricted: openSettings()
        case .authorizedAlways: break
        @unknown default: openSettings()
        }
    }

    func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in self?.refresh() }
    }
}

struct PermissionSetupView: View {
    @ObservedObject var permissions: PermissionSetupState
    let onContinue: () -> Void
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var bluetooth = BLERuntime.shared.bluetooth

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        Image(systemName: "tram.fill")
                            .font(.largeTitle).accessibilityHidden(true)
                        Text("Ready when you press the button")
                            .font(.title2.bold())
                        Text("Give TrainPod access to nearby stations and your tracker, including when your iPhone is locked.")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 8)
                }

                Section("1 · Location") {
                    Label(locationTitle, systemImage: locationAllowed ? "checkmark.circle.fill" : "location")
                    Text("Location selects nearby stations. No location tracking is started by this setup page.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    if permissions.locationAuthorization == .notDetermined {
                        Button("Allow location while using the app") { permissions.requestLocation() }
                    } else if !locationAllowed {
                        Text("Location is denied, restricted, or disabled. Check Settings → Privacy & Security → Location Services, then this app’s location access.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Open app settings") { permissions.openSettings() }
                    } else if !permissions.preciseLocation {
                        Text("Precise Location is off. Turn it on in the app’s location settings for reliable nearby-station selection.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Review location settings") { permissions.openSettings() }
                    }
                }

                Section("2 · Refresh while your phone is locked") {
                    Label(permissions.locationAuthorization == .authorizedAlways ? "Always location access enabled" : "Always location access needed",
                          systemImage: permissions.locationAuthorization == .authorizedAlways ? "checkmark.circle.fill" : "lock.iphone")
                    Text("Choose Always so a TrainPod button press can find nearby stations while your iPhone is locked. This does not mean continuous GPS tracking.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    if permissions.locationAuthorization == .authorizedWhenInUse {
                        Button("Allow Always location access") { permissions.requestLocation() }
                        Text("If iOS doesn’t show another prompt, open Settings → Location → Always. Allow Once may require granting While Using first.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Open app settings") { permissions.openSettings() }
                    } else if permissions.locationAuthorization != .authorizedAlways {
                        Text("Complete the location step above first. You can also review access in Settings.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                Section("3 · Bluetooth") {
                    Label(bluetoothTitle, systemImage: permissions.bluetoothAuthorization == .allowedAlways ? "checkmark.circle.fill" : "antenna.radiowaves.left.and.right")
                    Text("Bluetooth sends station data to your registered TrainPod. Permission is separate from whether Bluetooth is currently switched on.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    if permissions.bluetoothAuthorization == .notDetermined {
                        Text("Allow the iOS Bluetooth prompt when it appears. TrainPod’s existing Bluetooth setup requests this access; this page doesn’t start another connection.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if permissions.bluetoothAuthorization != .allowedAlways {
                        Button("Open Bluetooth permission settings") { permissions.openSettings() }
                    }
                }

                Section("4 · Background settings") {
                    Label(backgroundTitle, systemImage: permissions.backgroundRefresh == .available ? "checkmark.circle.fill" : "arrow.clockwise")
                    Text("Background App Refresh is a Settings option, not another permission pop-up. Check Settings → General → Background App Refresh if it is off.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    if permissions.lowPowerMode {
                        Text("Low Power Mode is on and can limit background activity. Review Settings → Battery when checking background refresh.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if permissions.backgroundRefresh != .available {
                        Button("Open app settings") { permissions.openSettings() }
                    }
                    Text("These settings help background operation; iOS still controls execution time. They cannot guarantee every refresh succeeds.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("After installing an update") {
                    Text("Open TrainPod once, confirm these settings, and leave it in the background. If the connection is paused, reconnect from Main. Swiping the app away can prevent Bluetooth from waking it again until you reopen it.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Text("Internet access uses Wi-Fi or cellular data; there is no extra internet permission prompt. If updates work on Wi-Fi only, check that cellular data is enabled for this app in Settings.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Section {
                    Button("Continue to TrainPod", action: onContinue)
                        .frame(maxWidth: .infinity)
                        .disabled(!permissions.requiredPermissionsGranted)
                    Text(permissions.requiredPermissionsGranted
                         ? "Always location and Bluetooth access are enabled. Review any background settings warnings above."
                         : "Enable Always location and Bluetooth access to finish setup. Your choices are rechecked when you return from Settings.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Set up your iPhone")
            .onAppear { permissions.refresh() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { permissions.refresh() }
            }
            .onReceive(bluetooth.$connectionState) { _ in permissions.refresh() }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.backgroundRefreshStatusDidChangeNotification)) { _ in
                permissions.refresh()
            }
        }
    }

    private var locationAllowed: Bool {
        permissions.locationAuthorization == .authorizedWhenInUse || permissions.locationAuthorization == .authorizedAlways
    }
    private var locationTitle: String {
        switch permissions.locationAuthorization {
        case .authorizedAlways, .authorizedWhenInUse: return "Location access enabled"
        case .notDetermined: return "Allow nearby-station lookup"
        case .denied: return "Location access is off"
        case .restricted: return "Location access is restricted"
        @unknown default: return "Review location access"
        }
    }
    private var bluetoothTitle: String {
        switch permissions.bluetoothAuthorization {
        case .allowedAlways: return "Bluetooth access enabled"
        case .notDetermined: return "Bluetooth access not decided"
        case .denied: return "Bluetooth access is off"
        case .restricted: return "Bluetooth access is restricted"
        @unknown default: return "Review Bluetooth access"
        }
    }
    private var backgroundTitle: String {
        switch permissions.backgroundRefresh {
        case .available: return "Background App Refresh available"
        case .denied: return "Background App Refresh unavailable"
        case .restricted: return "Background App Refresh restricted"
        @unknown default: return "Review background settings"
        }
    }
}
