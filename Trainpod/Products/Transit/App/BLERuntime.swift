import UIKit

/// Keep the existing production and test sessions alive independently of SwiftUI.
/// Construct both stable central identities on every launch, including restoration launches.
@MainActor
final class BLERuntime {
    static let shared = BLERuntime()
    let setup: TrainPodSetupController
    let bluetooth: BluetoothService
    let bridge: MessageBridge
    let provider: LiveTransitProvider
    let refreshHandler: RefreshRequestHandler
    let displayMode: DeviceDisplayMode
    let uiColor: DeviceUIColor
    let diagnostics: DeviceDiagnostics
    let testBluetooth: BluetoothService
    let testRunner: BLETestRunner

    private init() {
        // Test locations are opt-in for this app session. Reset before BLE can
        // request transit data, including launches for background restoration.
        UserDefaults.standard.set(MTALocationMode.current.rawValue,
                                  forKey: MTALocationMode.preferenceKey)
        setup = TrainPodSetupController()
        bluetooth = BluetoothService(configuration: TransitBLEConfiguration.current, role: "transit", autoConnect: true)
        bridge = MessageBridge(bluetooth: bluetooth, wireFormat: .plainText)
        uiColor = DeviceUIColor(bluetooth: bluetooth, bridge: bridge)
        displayMode = DeviceDisplayMode(bluetooth: bluetooth, bridge: bridge)
        provider = LiveTransitProvider()
        refreshHandler = RefreshRequestHandler(bluetooth: bluetooth, bridge: bridge, provider: provider)
        diagnostics = DeviceDiagnostics(bluetooth: bluetooth, bridge: bridge)
        testBluetooth = BluetoothService(configuration: TransitBLEConfiguration.current, role: "test", autoConnect: false)
        testRunner = BLETestRunner(bridge: MessageBridge(bluetooth: testBluetooth))
        setup.onComplete = { [weak self] in self?.bluetooth.scanAndConnect() }
    }

    enum DeviceSelectionError: LocalizedError {
        case transferActive
        var errorDescription: String? {
            "Wait for the current transfer, diagnostics download, or BLE test to finish before switching devices."
        }
    }

    private func checkDeviceSwitchAvailable() throws {
        guard !diagnostics.busy, !bridge.isSending, !testRunner.isRunning else {
            throw DeviceSelectionError.transferActive
        }
    }

    func setUpAnotherDevice() throws {
        try checkDeviceSwitchAvailable()
        // Commit first: a Keychain failure leaves the current connection intact.
        try TrainPodBindingStore.shared.beginAdditionalDeviceSetup()
        setup.stop()
        bluetooth.disconnect(); testBluetooth.disconnect()
        setup.start()
    }

    func useSavedDevice(_ deviceId: String) throws {
        try checkDeviceSwitchAvailable()
        try TrainPodBindingStore.shared.activateSavedDevice(deviceId: deviceId)
        setup.stop()
        bluetooth.disconnect(); testBluetooth.disconnect()
        bluetooth.scanAndConnect()
    }

    /// Local-only development API. Firmware reset remains deliberately separate.
    func forgetLocalBinding() throws {
        bluetooth.disconnect(); testBluetooth.disconnect()
        try TrainPodBindingStore.shared.clearBinding()
        setup.start()
    }
}

final class BLEAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Scene apps need not receive bluetoothCentrals in launchOptions.
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        FileLogger.shared.log("[APP] App launched version=\(version) build=\(build) state=\(application.applicationState.rawValue) bluetoothRestore=\(launchOptions?[.bluetoothCentrals] != nil)")
        PermissionSetupState.shared.refresh()
        PhoneDiagnosticLog.shared.record("APP_LAUNCHED")
        _ = BLERuntime.shared
        return true
    }
}
