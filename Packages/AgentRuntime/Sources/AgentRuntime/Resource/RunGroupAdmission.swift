// SPDX-License-Identifier: MIT

import AgentContracts
import Foundation

/// One progressing root family, with bounded sibling concurrency. Local decode ownership remains
/// in ResourceArbiter; this gate never loads a model or grants external authority.
actor RunGroupAdmission {
    struct Lease: Sendable { let token: UUID }
    private struct Waiter {
        let token: UUID
        let group: AgentRunID
        let sequence: UInt64
        let continuation: CheckedContinuation<Lease, Error>
    }
    private var group: AgentRunID?
    private var owners: Set<UUID> = []
    private var waiters: [Waiter] = []
    private let maximumSiblings = 16

    func acquire(group: AgentRunID, sequence: UInt64) async throws -> Lease {
        try Task.checkCancellation()
        let token = UUID()
        let lease = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters.append(Waiter(token: token, group: group, sequence: sequence, continuation: continuation))
                waiters.sort { $0.sequence < $1.sequence }
                drain()
            }
        } onCancel: {
            Task { await self.cancel(token) }
        }
        if Task.isCancelled { release(lease); throw CancellationError() }
        return lease
    }

    func release(_ lease: Lease) {
        guard owners.remove(lease.token) != nil else { return }
        if owners.isEmpty { group = nil }
        drain()
    }

    private func cancel(_ token: UUID) {
        guard let index = waiters.firstIndex(where: { $0.token == token }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
        drain()
    }

    private func drain() {
        if group == nil { group = waiters.first?.group }
        while owners.count < maximumSiblings, let next = waiters.first, next.group == group {
            waiters.removeFirst()
            owners.insert(next.token)
            next.continuation.resume(returning: Lease(token: next.token))
        }
    }
}
