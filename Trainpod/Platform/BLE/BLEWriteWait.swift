import Foundation

/// One transport suspension, owned by one peripheral/characteristic pair.
/// Keeping each wait separate prevents a delayed cancellation handler from
/// resolving a later operation. CoreBluetooth itself does not provide write IDs.
@MainActor
final class BLEWriteWait {
    private let peripheral: AnyObject
    private let characteristic: AnyObject
    private var continuation: CheckedContinuation<Void, Error>?

    init(peripheral: AnyObject, characteristic: AnyObject) {
        self.peripheral = peripheral
        self.characteristic = characteristic
    }

    var isPending: Bool { continuation != nil }

    func matches(peripheral: AnyObject, characteristic: AnyObject) -> Bool {
        self.peripheral === peripheral && self.characteristic === characteristic
    }

    func wait(start: () -> Void, onCancellation: @escaping @MainActor () -> Void) async throws {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                start()
            }
            try Task.checkCancellation()
        } onCancel: {
            Task { @MainActor in
                // Clear/resume first. Retirement (for response writes only) runs
                // in the same actor turn, before the released sender can proceed.
                if self.complete(.failure(CancellationError())) { onCancellation() }
            }
        }
    }

    @discardableResult
    func complete(_ result: Result<Void, Error>) -> Bool {
        guard let continuation else { return false }
        self.continuation = nil
        continuation.resume(with: result)
        return true
    }
}

/// Blocks reuse only until CoreBluetooth confirms disconnection. The existing
/// reconnect path, not this gate, owns recovery and subsequent discovery.
@MainActor
struct BLEWriteRetirement {
    private var peripheral: AnyObject?

    func blocks(_ candidate: AnyObject?) -> Bool {
        guard let peripheral, let candidate else { return false }
        return peripheral === candidate
    }

    mutating func retire(_ candidate: AnyObject) { peripheral = candidate }

    mutating func disconnected(_ candidate: AnyObject) {
        if blocks(candidate) { peripheral = nil }
    }
}
