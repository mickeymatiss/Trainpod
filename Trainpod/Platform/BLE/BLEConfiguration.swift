import CoreBluetooth
import Foundation

/// Product-supplied identity and presentation; connection mechanics remain in Platform.
struct BLEConfiguration {
    let deviceName: String
    let serviceUUID: CBUUID
    let characteristicUUID: CBUUID
    let restorationPrefix: String
    let loggerSubsystem: String
    let relatedNameFragments: [String]
    let connectedMessage: String
    let controlMessages: Set<Data>
    let ignoredControlMessage: String
    var supportsDiagnosticsTimeSync: Bool = false
    var deviceIdentityUUID: CBUUID? = nil
}
