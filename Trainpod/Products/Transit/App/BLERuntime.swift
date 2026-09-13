import UIKit

/// Keep the existing production and test sessions alive independently of SwiftUI.
/// Construct both stable central identities on every launch, including restoration launches.
@MainActor
final class BLERuntime {
    static let shared = BLERuntime()
    let bluetooth: BluetoothService
    let bridge: MessageBridge
    let provider: LiveTransitProvider
    let refreshHandler: RefreshRequestHandler
    let uiColor: DeviceUIColor
    let diagnostics: DeviceDiagnostics
    let testBluetooth: BluetoothService
    let testRunner: BLETestRunner

    private init() {
        bluetooth = BluetoothService(configuration: TransitBLEConfiguration.current, role: "transit", autoConnect: true)
        bridge = MessageBridge(bluetooth: bluetooth, wireFormat: .plainText)
        uiColor = DeviceUIColor(bluetooth: bluetooth, bridge: bridge)
        provider = LiveTransitProvider()
        refreshHandler = RefreshRequestHandler(bluetooth: bluetooth, bridge: bridge, provider: provider)
        diagnostics = DeviceDiagnostics(bluetooth: bluetooth, bridge: bridge)
        testBluetooth = BluetoothService(configuration: TransitBLEConfiguration.current, role: "test", autoConnect: false)
        testRunner = BLETestRunner(bridge: MessageBridge(bluetooth: testBluetooth))
    }
}

final class BLEAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Scene apps need not receive bluetoothCentrals in launchOptions.
        FileLogger.shared.log("[APP] App launched")
        PhoneDiagnosticLog.shared.record("APP_LAUNCHED")
        _ = BLERuntime.shared
        return true
    }
}
