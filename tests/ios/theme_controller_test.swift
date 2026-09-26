import Foundation
import UIKit

struct ThemeControllerChecks {
    @MainActor static func main() async {
        let bluetooth = BluetoothService(), bridge = MessageBridge()
        let controller = DeviceUIColor(bluetooth: bluetooth, bridge: bridge)
        let x = controller.selectedTheme
        let y = controller.themes.first { $0.colors != x.colors }!
        func acknowledge() {
            let packet = String(data: bridge.sends.last![0], encoding: .utf8)!
            let token = packet.split(separator: ":")[1]
            bluetooth.uiColorAcknowledgementHandler?(Data("TA:\(token):\(controller.selectedTheme.fingerprint)".utf8))
        }
        func waitForSends(_ count: Int) async {
            for _ in 0..<10000 {
                if bridge.sends.count >= count { return }
                await Task.yield()
            }
            preconditionFailure("Expected theme send \(count)")
        }
        // A confirms X using the real token/fingerprint/controller path.
        controller.push()
        await waitForSends(1)
        precondition(bridge.sends[0].count == 7) // Six fields + commit, unchanged.
        acknowledge()
        precondition(controller.deviceTheme == x && controller.pushState == .success)
        controller.liveEnabled = true
        controller.selectedThemeID = y.id
        controller.selectedThemeID = x.id
        for _ in 0..<100 { await Task.yield() }
        precondition(bridge.sends.count == 1, "Same-connection confirmed X must deduplicate")

        // Switch to B: selection persists, confirmation must not.
        bluetooth.uiColorConnectionStateHandler?(.disconnected)
        precondition(controller.deviceTheme == nil, "A's confirmation leaked into B's connection")
        precondition(controller.selectedTheme == x && !controller.liveEnabled)
        bluetooth.uiColorConnectionStateHandler?(.connected)
        controller.selectedThemeID = y.id
        controller.liveEnabled = true
        controller.selectedThemeID = x.id
        await waitForSends(2)
        acknowledge()
        precondition(controller.deviceTheme == x)

        // Back to A: B's X confirmation must not suppress A's next edit to X.
        bluetooth.uiColorConnectionStateHandler?(.connecting)
        precondition(controller.deviceTheme == nil)
        bluetooth.uiColorConnectionStateHandler?(.connected)
        controller.selectedThemeID = y.id
        controller.liveEnabled = true
        controller.selectedThemeID = x.id
        await waitForSends(3)
        acknowledge()
        // Manual Push remains explicit even for an already confirmed palette.
        controller.push()
        await waitForSends(4)
        acknowledge()
        precondition(controller.pushState == .success)
        print("PASS real theme controller: A/B/A confirmation invalidation, same-device dedup, live edit, manual Push, six-field payload")
    }
}

@main final class ThemeHarnessApp: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        Task { @MainActor in
            await ThemeControllerChecks.main()
            exit(0)
        }
        return true
    }
}
