import Foundation

@main struct BLEWriteWaitChecks {
    enum Failure: Error { case write, disconnect, superseded }

    @MainActor static func installed(_ wait: BLEWriteWait) async {
        // Actor handoff, not wall-clock timing. The host runner bounds the process.
        while !wait.isPending { await Task.yield() }
    }

    @MainActor static func cancelled(_ task: Task<Void, Error>) async {
        do { try await task.value; preconditionFailure("Expected cancellation") }
        catch is CancellationError { }
        catch { preconditionFailure("Unexpected error: \(error)") }
    }

    @MainActor static func main() async throws {
        let peer = NSObject(), otherPeer = NSObject(), oldHandle = NSObject()
        var retirement = BLEWriteRetirement()
        var retirementCount = 0
        var released = 0
        var submissions = 0

        // Normal response completion, explicit failure, disconnect, supersession.
        for result: Result<Void, Error> in [.success(()), .failure(Failure.write),
                                           .failure(Failure.disconnect), .failure(Failure.superseded)] {
            let wait = BLEWriteWait(peripheral: peer, characteristic: oldHandle)
            let task = Task { @MainActor in
                defer { released += 1 }
                try await wait.wait(start: { submissions += 1 }, onCancellation: { retirementCount += 1 })
            }
            await installed(wait)
            precondition(wait.complete(result))
            precondition(!wait.complete(result), "A duplicate callback must not resume twice")
            switch result {
            case .success: try await task.value
            case .failure:
                do { try await task.value; preconditionFailure("Expected transport failure") }
                catch is Failure { }
            }
            task.cancel() // Completed transport operations must not retire a connection.
            await Task.yield()
            precondition(retirementCount == 0)
        }
        precondition(released == 4 && submissions == 4)

        // Cancel a response write. Observe resolution BEFORE the retirement action.
        let abandoned = BLEWriteWait(peripheral: peer, characteristic: oldHandle)
        let task = Task { @MainActor in
            defer { released += 1 }
            try await abandoned.wait(start: { submissions += 1 }, onCancellation: {
                precondition(!abandoned.isPending)
                retirement.retire(peer)
                retirementCount += 1
            })
        }
        await installed(abandoned)
        task.cancel()
        await cancelled(task)
        precondition(released == 5 && retirementCount == 1)
        precondition(retirement.blocks(peer) && !retirement.blocks(otherPeer))
        precondition(!abandoned.complete(.success(())), "Late old callback must be harmless")
        precondition(!abandoned.complete(.failure(Failure.disconnect)))
        retirement.disconnected(otherPeer)
        precondition(retirement.blocks(peer), "Unrelated disconnect must not reopen the old connection")

        // The real disconnect barrier invalidates GATT handles. Reconnect uses a
        // newly discovered handle; no fake peripheral or reconnect algorithm here.
        retirement.disconnected(peer)
        precondition(!retirement.blocks(peer))
        let newHandle = NSObject()
        let subsequent = BLEWriteWait(peripheral: peer, characteristic: newHandle)
        let next = Task { @MainActor in
            defer { released += 1 }
            try await subsequent.wait(start: { submissions += 1 }, onCancellation: {
                retirement.retire(peer); retirementCount += 1
            })
        }
        await installed(subsequent)
        precondition(!subsequent.matches(peripheral: peer, characteristic: oldHandle))
        precondition(!subsequent.matches(peripheral: otherPeer, characteristic: newHandle))
        precondition(!abandoned.complete(.success(())))
        precondition(subsequent.isPending, "An old callback cannot resolve the new wait")
        precondition(subsequent.matches(peripheral: peer, characteristic: newHandle))
        precondition(subsequent.complete(.success(())))
        try await next.value
        precondition(released == 6 && retirementCount == 1)

        // Cancellation before installing a wait must submit nothing and retire nothing.
        let neverStarted = BLEWriteWait(peripheral: peer, characteristic: newHandle)
        let early = Task { @MainActor in
            try await neverStarted.wait(start: { preconditionFailure("Cancelled before submission") },
                                        onCancellation: { preconditionFailure("No operation to retire") })
        }
        early.cancel() // Same actor: task body cannot have started yet.
        await cancelled(early)
        precondition(!neverStarted.isPending)

        // Completion wins before the queued cancellation handler: no retirement.
        let won = BLEWriteWait(peripheral: peer, characteristic: newHandle)
        let race = Task { @MainActor in
            try await won.wait(start: {}, onCancellation: { preconditionFailure("Completion already resolved") })
        }
        await installed(won)
        race.cancel()
        precondition(won.complete(.success(())))
        await cancelled(race)

        // Readiness is capacity, not an outstanding response. Cancellation releases
        // the wait but must NOT retire the connection. The next readiness wait works.
        for cancel in [true, false] {
            let ready = BLEWriteWait(peripheral: peer, characteristic: newHandle)
            var removed = false
            let readiness = Task { @MainActor in
                try await ready.wait(start: {}, onCancellation: { removed = true })
            }
            await installed(ready)
            if cancel { readiness.cancel(); await cancelled(readiness); precondition(removed) }
            else { precondition(ready.complete(.success(()))); try await readiness.value }
            precondition(!retirement.blocks(peer) && retirementCount == 1)
        }
        print("PASS BLE wait completion/failure/disconnect/supersession, cancellation races, retirement barrier, late callback ownership, subsequent write, readiness cancellation")
    }
}
