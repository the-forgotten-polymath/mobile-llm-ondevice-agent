// SPDX-License-Identifier: MIT

import XCTest
import AgentContracts
@testable import MobileLLMUI

// TEST-ID: AHT-WORKFLOW-001
// TEST-ID: AHT-DYNAMIC-001
@MainActor
final class WorkflowStoreTests: XCTestCase {
    func testSaveLoadRoundTripAndRunningFlag() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("workflow-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WorkflowStore(directory: directory)
        let workflowID = UUID()
        let summary = WorkflowSummary(
            id: workflowID,
            title: "Research",
            conversationID: UUID(),
            plan: try WorkflowPlan(
                goal: "Research",
                phases: [WorkflowPhasePlan(
                    sequence: 1,
                    title: "Goal",
                    acceptanceCriteria: "Done",
                    childInstructions: ["Research"]
                )]
            ),
            status: .running,
            rootRunID: AgentRunID(rawValue: UUID())
        )

        try await store.save(summary)
        XCTAssertTrue(store.hasRunningWorkflow)
        XCTAssertEqual(store.messageRecord(workflowID: workflowID)?.title, "Research")

        let reloaded = WorkflowStore(directory: directory)
        reloaded.load()
        XCTAssertEqual(reloaded.summary(workflowID: workflowID), summary)
        XCTAssertTrue(reloaded.hasRunningWorkflow)
    }

    func testCompletedWorkflowStopsRunningAndRefreshFires() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("workflow-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WorkflowStore(directory: directory)
        let workflowID = UUID()
        var changed: [UUID] = []
        store.onWorkflowChanged = { changed.append($0) }

        try await store.save(WorkflowSummary(id: workflowID, title: "T", status: .running))
        var completed = try XCTUnwrap(store.summary(workflowID: workflowID))
        completed.status = .completed
        completed.endTime = Date()
        try await store.save(completed)

        XCTAssertEqual(changed, [workflowID, workflowID])
        XCTAssertFalse(store.hasRunningWorkflow)
        XCTAssertEqual(store.messageRecord(workflowID: workflowID)?.status, .completed)
    }

    func testLoadingRunningWorkflowNeverResumesUntilExplicitAction() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("workflow-resume-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let workflowID = UUID()
        let writer = WorkflowStore(directory: directory)
        try await writer.save(WorkflowSummary(id: workflowID, title: "Interrupted", status: .running))

        let reloaded = WorkflowStore(directory: directory)
        var resumeCount = 0
        reloaded.resumeHandler = { id in
            XCTAssertEqual(id, workflowID)
            resumeCount += 1
        }
        reloaded.load()

        XCTAssertEqual(resumeCount, 0, "neutral launch must not restart durable work")
        XCTAssertFalse(reloaded.executingWorkflowIDs.contains(workflowID))
        await reloaded.resume(workflowID: workflowID)
        XCTAssertEqual(resumeCount, 1)
        XCTAssertTrue(reloaded.executingWorkflowIDs.contains(workflowID))
        XCTAssertTrue(reloaded.resumingWorkflowIDs.isEmpty)
    }

    func testResumeFailureIsVisibleAndDoesNotChangeDurableRunningState() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("workflow-resume-error-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let workflowID = UUID()
        let writer = WorkflowStore(directory: directory)
        try await writer.save(WorkflowSummary(id: workflowID, title: "Interrupted", status: .running))
        let store = WorkflowStore(directory: directory)
        store.load()
        struct ResumeFailure: LocalizedError {
            var errorDescription: String? { "fixture failed" }
        }
        store.resumeHandler = { _ in throw ResumeFailure() }

        await store.resume(workflowID: workflowID)

        XCTAssertEqual(store.summary(workflowID: workflowID)?.status, .running)
        XCTAssertEqual(store.lastError, "Workflow could not resume: fixture failed")
        XCTAssertFalse(store.executingWorkflowIDs.contains(workflowID))
        XCTAssertTrue(store.resumingWorkflowIDs.isEmpty)
    }

    func testPendingDynamicApprovalSurvivesRelaunchWithoutStarting() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("workflow-dynamic-pending-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let workflowID = UUID()
        let runID = WorkflowRunID(rawValue: workflowID)
        let writer = WorkflowStore(directory: directory)
        try await writer.save(WorkflowSummary(
            id: workflowID,
            title: "Review me",
            conversationID: UUID(),
            dynamic: DynamicWorkflowPresentation(
                runID: runID,
                source: "export const meta = {};",
                state: .waitingForLaunchApproval
            )
        ))

        let reloaded = WorkflowStore(directory: directory)
        var startCount = 0
        reloaded.dynamicStartHandler = { _ in startCount += 1 }
        reloaded.load()

        XCTAssertEqual(reloaded.summary(workflowID: workflowID)?.dynamic?.runID, runID)
        XCTAssertEqual(
            reloaded.messageRecord(workflowID: workflowID)?.dynamic?.state,
            .waitingForLaunchApproval
        )
        XCTAssertEqual(startCount, 0, "loading a pending approval must remain projection-only")
        XCTAssertFalse(reloaded.executingWorkflowIDs.contains(workflowID))
    }

    func testDynamicRunUsesOneRecoveryActionWithoutReusableApprovalChoice() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("workflow-dynamic-actions-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let workflowID = UUID()
        let store = WorkflowStore(directory: directory)
        try await store.save(WorkflowSummary(
            id: workflowID,
            title: "Explicit control",
            dynamic: DynamicWorkflowPresentation(
                runID: WorkflowRunID(rawValue: workflowID),
                state: .waitingForLaunchApproval
            )
        ))
        var runCount = 0
        store.dynamicRunHandler = { id in
            XCTAssertEqual(id, workflowID)
            runCount += 1
        }

        await store.runDynamic(workflowID: workflowID)
        XCTAssertEqual(runCount, 1)
        XCTAssertTrue(store.actioningWorkflowIDs.isEmpty)
    }

    func testDynamicReconciliationForwardsExactDecisionWithoutGenericResume() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("workflow-dynamic-reconcile-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let workflowID = UUID()
        let store = WorkflowStore(directory: directory)
        try await store.save(WorkflowSummary(
            id: workflowID,
            title: "Reconcile uncertain action",
            dynamic: DynamicWorkflowPresentation(
                runID: WorkflowRunID(rawValue: workflowID),
                state: .waitingForReconciliation,
                reconciliationCallID: WorkflowAgentCallID()
            )
        ))
        var reconciliations: [AgentReconciliationDecision] = []
        var resumeCount = 0
        store.dynamicReconcileHandler = { id, decision in
            XCTAssertEqual(id, workflowID)
            reconciliations.append(decision)
        }
        store.dynamicResumeHandler = { _ in resumeCount += 1 }

        await store.reconcileDynamic(workflowID: workflowID, decision: .abandoned)

        XCTAssertEqual(reconciliations, [.abandoned])
        XCTAssertEqual(resumeCount, 0, "reconciliation must not be represented as a generic resume")
        XCTAssertTrue(store.actioningWorkflowIDs.isEmpty)
    }

    // TEST-ID: AHT-DYNAMIC-UI-001
    func testRunningJournalProjectionRemainsInterruptedUntilExplicitAttachment() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("workflow-dynamic-interrupted-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let workflowID = UUID()
        let writer = WorkflowStore(directory: directory)
        try await writer.save(WorkflowSummary(
            id: workflowID,
            title: "Interrupted",
            dynamic: DynamicWorkflowPresentation(
                runID: WorkflowRunID(rawValue: workflowID),
                state: .running
            )
        ))

        let reloaded = WorkflowStore(directory: directory)
        reloaded.load()
        var projected = try XCTUnwrap(reloaded.summary(workflowID: workflowID))
        projected.dynamic?.logs = ["journal replayed"]
        try await reloaded.save(projected)

        XCTAssertFalse(reloaded.executingWorkflowIDs.contains(workflowID))
        XCTAssertEqual(
            reloaded.messageRecord(workflowID: workflowID)?.isAttachedInCurrentProcess,
            false
        )

        reloaded.markDynamicExecutionAttached(workflowID: workflowID)
        XCTAssertTrue(reloaded.executingWorkflowIDs.contains(workflowID))
        XCTAssertEqual(
            reloaded.messageRecord(workflowID: workflowID)?.isAttachedInCurrentProcess,
            true
        )
    }

    func testDynamicRestartForwardsExactCallWithoutGenericResume() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("workflow-dynamic-restart-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let workflowID = UUID()
        let callID = WorkflowAgentCallID()
        let store = WorkflowStore(directory: directory)
        try await store.save(WorkflowSummary(
            id: workflowID,
            title: "Restart",
            dynamic: DynamicWorkflowPresentation(
                runID: WorkflowRunID(rawValue: workflowID),
                state: .paused
            )
        ))
        var received: (UUID, WorkflowAgentCallID)?
        store.dynamicRestartHandler = { received = ($0, $1) }

        await store.restartDynamic(workflowID: workflowID, callID: callID)

        XCTAssertEqual(received?.0, workflowID)
        XCTAssertEqual(received?.1, callID)
    }
}
