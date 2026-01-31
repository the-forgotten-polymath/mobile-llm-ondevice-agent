// SPDX-License-Identifier: MIT

import AgentContracts

extension AgentRunController {
    func beginPublicMutation() throws {
        guard !dataEraseSuspended else { throw AgentExecutionError.internalInvariant("data erasure in progress") }
        publicMutations += 1
    }

    func endPublicMutation() {
        publicMutations -= 1
        if publicMutations == 0 {
            let waiters = mutationDrainWaiters
            mutationDrainWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
    }

    /// Blocks submission/commands and drains every writer before the owner may close/delete stores.
    public func suspendForDataErase() async throws {
        dataEraseSuspended = true
        let pending = Array(workers.values)
        for task in pending { task.cancel() }
        for runID in Array(activeToolCancellations.keys) { await cancelActiveTool(runID: runID) }
        for task in pending { await task.value }
        if publicMutations > 0 { await withCheckedContinuation { mutationDrainWaiters.append($0) } }
        let state = await arbiter.snapshot()
        if let selection = state.residentSelection {
            try await residencyDriver.cancelAndDrain(selection: selection)
            try await residencyDriver.unload(selection: selection)
        }
        discardObserversForDataErase()
        workers.removeAll()
        activeToolCancellations.removeAll()
        toolCommitGates.removeAll()
    }

    public func resumeAfterDataErase() {
        precondition(publicMutations == 0 && workers.isEmpty)
        arbiter = ResourceArbiter(driver: residencyDriver)
        dataEraseSuspended = false
    }
}
