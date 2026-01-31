// SPDX-License-Identifier: MIT

import Foundation

public enum WorkflowDispatchSchedulerError: Error, Hashable, Sendable {
    case stopped
}

public enum WorkflowDispatchSchedulerState: String, Hashable, Codable, Sendable {
    case running
    case pausing
    case paused
    case stopped
}

/// Fair dispatch-layer limiter shared by every `agent()` call in a workflow. A permit covers only
/// child execution, never script evaluation or nested orchestration, avoiding nested-parallel
/// deadlocks while preserving a hard global fan-out bound.
public actor WorkflowDispatchScheduler {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    public let maximumConcurrentAgents: Int
    private var active = 0
    private var waiters: [Waiter] = []
    private var pauseWaiters: [Waiter] = []
    private var stateValue: WorkflowDispatchSchedulerState = .running

    public init(maximumConcurrentAgents: Int) {
        self.maximumConcurrentAgents = max(1, min(16, maximumConcurrentAgents))
    }

    public var state: WorkflowDispatchSchedulerState { stateValue }
    public var activeCount: Int { active }
    public var waitingCount: Int { waiters.count }

    public func run<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await acquire()
        do {
            let result = try await operation()
            release()
            return result
        } catch {
            release()
            throw error
        }
    }

    public func pause() {
        guard stateValue == .running else { return }
        stateValue = active == 0 ? .paused : .pausing
        if stateValue == .paused { settlePauseWaiters() }
    }

    public func waitUntilPaused() async throws {
        if stateValue == .paused { return }
        guard stateValue == .pausing else {
            if stateValue == .stopped { throw WorkflowDispatchSchedulerError.stopped }
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pauseWaiters.append(Waiter(id: id, continuation: continuation))
                if Task.isCancelled { cancelPauseWaiter(id) }
            }
        } onCancel: {
            Task { await self.cancelPauseWaiter(id) }
        }
    }

    public func resume() {
        guard stateValue == .paused || stateValue == .pausing else { return }
        stateValue = .running
        drain()
    }

    public func stop() {
        guard stateValue != .stopped else { return }
        stateValue = .stopped
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.continuation.resume(throwing: WorkflowDispatchSchedulerError.stopped) }
        let pendingPause = pauseWaiters
        pauseWaiters.removeAll()
        for waiter in pendingPause {
            waiter.continuation.resume(throwing: WorkflowDispatchSchedulerError.stopped)
        }
    }

    private func acquire() async throws {
        try Task.checkCancellation()
        guard stateValue != .stopped else { throw WorkflowDispatchSchedulerError.stopped }
        if stateValue == .running, active < maximumConcurrentAgents, waiters.isEmpty {
            active += 1
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters.append(Waiter(id: id, continuation: continuation))
                if Task.isCancelled { cancelWaiter(id) }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func cancelPauseWaiter(_ id: UUID) {
        guard let index = pauseWaiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = pauseWaiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func release() {
        precondition(active > 0)
        active -= 1
        if stateValue == .pausing, active == 0 {
            stateValue = .paused
            settlePauseWaiters()
        }
        drain()
    }

    private func drain() {
        guard stateValue == .running else { return }
        while active < maximumConcurrentAgents, !waiters.isEmpty {
            let waiter = waiters.removeFirst()
            active += 1
            waiter.continuation.resume()
        }
    }

    private func settlePauseWaiters() {
        let pending = pauseWaiters
        pauseWaiters.removeAll()
        for waiter in pending { waiter.continuation.resume() }
    }
}
