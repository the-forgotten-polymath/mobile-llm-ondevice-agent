// SPDX-License-Identifier: MIT

import AgentContracts
import Foundation

public enum WorkflowJournalError: Error, Hashable, Sendable {
    case scriptConflict
    case scriptNotFound
    case runNotFound
    case stale(expectedSequence: UInt64, actualSequence: UInt64)
    case eventIdentityConflict
    case corrupt(String)
    case unavailable(String)
}

public enum WorkflowJournalAppendDisposition: String, Hashable, Codable, Sendable {
    case appended
    case replayed
}

public struct WorkflowJournalAppendReceipt: Hashable, Sendable {
    public let disposition: WorkflowJournalAppendDisposition
    public let projection: WorkflowRunProjectionV1
    public let eventIDs: [WorkflowEventID]

    public init(
        disposition: WorkflowJournalAppendDisposition,
        projection: WorkflowRunProjectionV1,
        eventIDs: [WorkflowEventID]
    ) {
        self.disposition = disposition
        self.projection = projection
        self.eventIDs = eventIDs
    }
}

public struct WorkflowJournalEventPage: Hashable, Sendable {
    public let events: [WorkflowRunEventV1]
    public let reachedEnd: Bool

    public init(events: [WorkflowRunEventV1], reachedEnd: Bool) {
        self.events = events
        self.reachedEnd = reachedEnd
    }
}

/// Append-only persistence boundary for source, events, and projections. Implementations must make
/// CAS validation, event insertion, and the run-head update one atomic transaction.
public protocol DynamicWorkflowJournal: Sendable {
    func saveScript(_ script: SavedWorkflowScriptV1) async throws
    func loadScript(
        _ reference: WorkflowScriptReferenceV1,
        owners: [WorkflowScriptOwnerV1]
    ) async throws -> SavedWorkflowScriptV1?
    func resolveScript(
        named name: String,
        owners: [WorkflowScriptOwnerV1]
    ) async throws -> SavedWorkflowScriptV1?
    func listScripts(owners: [WorkflowScriptOwnerV1]) async throws -> [SavedWorkflowScriptV1]
    func saveLaunchApproval(_ approval: WorkflowLaunchApprovalV1) async throws
    func reusableLaunchApproval(for launch: WorkflowLaunchSnapshotV1) async throws -> WorkflowLaunchApprovalV1?
    func loadProjection(for runID: WorkflowRunID) async throws -> WorkflowRunProjectionV1?
    func append(_ request: WorkflowEventAppendRequestV1) async throws -> WorkflowJournalAppendReceipt
    func readEvents(runID: WorkflowRunID, after sequence: UInt64, limit: Int) async throws -> WorkflowJournalEventPage
}

/// Deterministic journal for scheduler/engine tests. It implements the same exact-replay and CAS
/// semantics as SQLite rather than acting as a permissive mock.
public actor InMemoryDynamicWorkflowJournal: DynamicWorkflowJournal {
    private struct ScriptKey: Hashable {
        let digest: StableDigest
        let owner: WorkflowScriptOwnerV1
    }
    private var scripts: [ScriptKey: SavedWorkflowScriptV1] = [:]
    private var events: [WorkflowRunID: [WorkflowRunEventV1]] = [:]
    private var launchApprovals: [ApprovalID: WorkflowLaunchApprovalV1] = [:]

    public init() {}

    public func saveScript(_ script: SavedWorkflowScriptV1) throws {
        let digest = script.script.sourceDigest
        let key = ScriptKey(digest: digest, owner: script.owner)
        if let existing = scripts[key] {
            guard existing == script else { throw WorkflowJournalError.scriptConflict }
            return
        }
        guard !scripts.values.contains(where: {
            $0.owner == script.owner
                && $0.script.scriptID == script.script.scriptID
                && $0.script.version == script.script.version
        }) else { throw WorkflowJournalError.scriptConflict }
        scripts[key] = script
    }

    public func loadScript(
        _ reference: WorkflowScriptReferenceV1,
        owners: [WorkflowScriptOwnerV1]
    ) -> SavedWorkflowScriptV1? {
        for owner in owners {
            if let saved = scripts[ScriptKey(digest: reference.sourceDigest, owner: owner)],
               saved.script.reference == reference
            { return saved }
        }
        return nil
    }

    public func resolveScript(
        named name: String,
        owners: [WorkflowScriptOwnerV1]
    ) -> SavedWorkflowScriptV1? {
        for owner in owners {
            let candidates = scripts.values.filter { saved in
                saved.owner == owner && saved.metadata.name == name
            }.sorted { lhs, rhs in
                if lhs.script.version != rhs.script.version { return lhs.script.version > rhs.script.version }
                return lhs.createdAt > rhs.createdAt
            }
            if let match = candidates.first { return match }
        }
        return nil
    }

    public func listScripts(owners: [WorkflowScriptOwnerV1]) -> [SavedWorkflowScriptV1] {
        let allowed = Set(owners)
        return scripts.values.filter { allowed.contains($0.owner) }.sorted {
            if $0.metadata.name != $1.metadata.name { return $0.metadata.name < $1.metadata.name }
            return $0.script.version > $1.script.version
        }
    }

    public func saveLaunchApproval(_ approval: WorkflowLaunchApprovalV1) throws {
        if let existing = launchApprovals[approval.approvalID] {
            guard existing == approval else { throw WorkflowJournalError.scriptConflict }
            return
        }
        launchApprovals[approval.approvalID] = approval
    }

    public func reusableLaunchApproval(
        for launch: WorkflowLaunchSnapshotV1
    ) throws -> WorkflowLaunchApprovalV1? {
        try launchApprovals.values
            .filter { try $0.authorizes(launch) }
            .sorted { $0.createdAt > $1.createdAt }
            .first
    }

    public func loadProjection(for runID: WorkflowRunID) throws -> WorkflowRunProjectionV1? {
        try WorkflowRunProjectionV1.replay(events[runID] ?? [])
    }

    public func append(_ request: WorkflowEventAppendRequestV1) throws -> WorkflowJournalAppendReceipt {
        let current = events[request.runID] ?? []
        if current.count >= request.events.count {
            let byID = Dictionary(uniqueKeysWithValues: current.map { ($0.eventID, $0) })
            let matches = request.events.allSatisfy { byID[$0.eventID] == $0 }
            if matches, let projection = try WorkflowRunProjectionV1.replay(current) {
                return WorkflowJournalAppendReceipt(
                    disposition: .replayed,
                    projection: projection,
                    eventIDs: request.events.map(\.eventID)
                )
            }
            if request.events.contains(where: { byID[$0.eventID] != nil }) {
                throw WorkflowJournalError.eventIdentityConflict
            }
        }
        let actualSequence = UInt64(current.count)
        let actualDigest = current.last?.recordDigest
        guard actualSequence == request.expectedSequence, actualDigest == request.expectedDigest else {
            throw WorkflowJournalError.stale(
                expectedSequence: request.expectedSequence,
                actualSequence: actualSequence
            )
        }
        if current.isEmpty, case .created(let launch) = request.events[0].kind {
            guard loadScript(
                launch.scriptReference,
                owners: launch.savedWorkflowOwners
            ) != nil else {
                throw WorkflowJournalError.scriptNotFound
            }
        }
        let combined = current + request.events
        guard let projection = try WorkflowRunProjectionV1.replay(combined) else {
            throw WorkflowJournalError.corrupt("append produced an empty projection")
        }
        events[request.runID] = combined
        return WorkflowJournalAppendReceipt(
            disposition: .appended,
            projection: projection,
            eventIDs: request.events.map(\.eventID)
        )
    }

    public func readEvents(
        runID: WorkflowRunID,
        after sequence: UInt64,
        limit: Int
    ) throws -> WorkflowJournalEventPage {
        guard (1 ... 1_024).contains(limit) else {
            throw WorkflowJournalError.corrupt("invalid read limit")
        }
        let available = (events[runID] ?? []).filter { $0.sequence > sequence }
        return WorkflowJournalEventPage(
            events: Array(available.prefix(limit)),
            reachedEnd: available.count <= limit
        )
    }
}
