import Foundation

// Runtime experiment, not a mock of CoreBluetooth or a production regression test.
// Reproduces the primitive used at BluetoothService.swift's two suspension sites.
@main struct ContinuationProbe {
    @MainActor static func main() async {
        var pending: CheckedContinuation<Void, Error>?
        var exited = false
        let task = Task { @MainActor in
            defer { exited = true }
            try await withCheckedThrowingContinuation { (wait: CheckedContinuation<Void, Error>) in
                pending = wait
            }
        }
        while pending == nil { await Task.yield() }
        task.cancel()
        for _ in 0..<20 { await Task.yield() }
        precondition(task.isCancelled)
        precondition(!exited, "Unexpected automatic cancellation of checked continuation")
        print("OBSERVED: Task cancellation leaves the checked continuation suspended; enclosing defer has not run.")
        let wait = pending!
        pending = nil
        wait.resume(throwing: CancellationError())
        do { try await task.value; fatalError("Expected cancellation") }
        catch is CancellationError { }
        catch { fatalError("Unexpected error: \(error)") }
        precondition(exited)
        print("OBSERVED: Explicit continuation failure releases the task and its defer.")
    }
}
