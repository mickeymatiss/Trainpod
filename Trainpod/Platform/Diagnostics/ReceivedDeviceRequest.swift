import Foundation

struct ReceivedDeviceRequest: Identifiable {
    let id = UUID()
    let receivedAt: Date
    let name: String
    let transactionID: String?
    let byteCount: Int
    let backgrounded: Bool
    let ignored: Bool
}
