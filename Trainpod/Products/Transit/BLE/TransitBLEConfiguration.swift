import CoreBluetooth
import Foundation

enum TransitBLEConfiguration {
    static let current = BLEConfiguration(
        deviceName: "CTA Tracker",
        serviceUUID: CBUUID(string: "7A1C0001-8F4A-4D2B-9A57-1C2D3E4F5001"),
        characteristicUUID: CBUUID(string: "7A1C0002-8F4A-4D2B-9A57-1C2D3E4F5001"),
        restorationPrefix: "com.trainpod.ble.central",
        loggerSubsystem: "com.trainpod",
        relatedNameFragments: ["cta", "tracker"],
        connectedMessage: "Ready to send train data.",
        controlMessages: [Data("NEED_DATA".utf8), Data("REFRESH_REQUEST".utf8)],
        ignoredControlMessage: "[E2E] NEED_DATA ignored: reconnect-only test is armed",
        supportsDiagnosticsTimeSync: true,
        deviceIdentityUUID: CBUUID(string: "7A1C0003-8F4A-4D2B-9A57-1C2D3E4F5001"))
}
