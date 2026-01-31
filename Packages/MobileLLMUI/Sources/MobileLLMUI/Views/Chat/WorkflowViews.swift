// SPDX-License-Identifier: MIT

import SwiftUI
import AppUI
import AgentContracts

/// The message-anchored workflow record row (spec §20/§23): a live Claude Code-style record below
/// its initiating message, clickable to the summary page in its completed state.
struct WorkflowMessageRow: View {
    let record: WorkflowMessageRecord

    var body: some View {
        HStack(spacing: Theme.Space.sm) {
            Image(systemName: statusSymbol)
                .font(.subheadline)
                .foregroundStyle(statusColor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(record.title.isEmpty ? "Workflow" : "workflow: \(record.title)")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.textTertiary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.vertical, Theme.Space.sm)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .strokeBorder(Theme.hairline)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Workflow: \(record.title)")
        .accessibilityValue(statusText)
        .accessibilityIdentifier("workflow.row")
    }

    private var statusSymbol: String {
        switch record.status {
        case .running: "arrow.triangle.2.circlepath"
        case .completed: "checkmark.circle.fill"
        case .failed: "xmark.octagon.fill"
        case .cancelled: "minus.circle.fill"
        }
    }

    private var statusColor: Color {
        switch record.status {
        case .running: Theme.accent
        case .completed: Theme.fitGreen
        case .failed: Theme.danger
        case .cancelled: Theme.textTertiary
        }
    }

    private var statusText: String {
        if let dynamic = record.dynamic {
            var parts = [dynamic.state.displayLabel(
                attached: record.isAttachedInCurrentProcess == true
            )]
            if let phase = dynamic.currentPhase { parts.append(phase) }
            if dynamic.totalCallCount > 0 {
                parts.append("\(dynamic.completedCallCount)/\(dynamic.totalCallCount) agents")
            }
            return parts.joined(separator: " · ")
        }
        switch record.status {
        case .running:
            var parts = ["Running"]
            if record.totalPhaseCount > 0 {
                let current = min(record.completedPhaseCount + 1, record.totalPhaseCount)
                parts.append("phase \(current)/\(record.totalPhaseCount)")
            }
            parts.append(
                "\(record.completedSubagentCount)/\(record.totalSubagentCount) subagents"
            )
            if record.aggregated.inputTokens + record.aggregated.outputTokens > 0
                || record.aggregated.toolInvocationCount > 0
            {
                parts.append(
                    Format.shortCount(
                        record.aggregated.inputTokens + record.aggregated.outputTokens
                    ) + " tokens · "
                        + "\(Format.shortCount(record.aggregated.toolInvocationCount)) tool calls"
                )
            }
            return parts.joined(separator: " · ")
        case .completed:
            return "Completed · \(record.completedPhaseCount)/\(record.totalPhaseCount) phases · "
                + "\(record.completedSubagentCount)/\(record.totalSubagentCount) subagents · "
                + Format.shortCount(record.aggregated.inputTokens + record.aggregated.outputTokens)
                + " tokens · \(Format.shortCount(record.aggregated.toolInvocationCount)) tool calls"
        case .failed:
            return "Failed"
        case .cancelled:
            return "Cancelled"
        }
    }
}

/// The unified workflow page (spec §20/§34): legacy staged records retain their phase tree while
/// Dynamic Workflows expose the exact source, runtime activity, and durable run controls.
struct WorkflowSummaryPage: View {
    let store: WorkflowStore?
    let conversationID: UUID?

    private var workflows: [WorkflowSummary] {
        guard let store else { return [] }
        return store.workflows.values
            .filter { conversationID == nil || $0.conversationID == conversationID }
            .sorted { $0.startTime > $1.startTime }
    }

    var body: some View {
        Group {
            if workflows.isEmpty {
                CapabilityEmptyState(
                    icon: "point.3.connected.trianglepath.dotted",
                    title: "No workflow is running",
                    message: "Workflow candidates and running workflows appear here with their "
                        + "source, status, activity, and controls. The Workflow menu entry enables "
                        + "itself only while a workflow is active in this conversation."
                )
            } else {
                List {
                    if let error = store?.lastError {
                        Section {
                            Label(error, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(Theme.danger)
                                .accessibilityIdentifier("workflow.error")
                        }
                    }
                    ForEach(workflows) { workflow in
                        Section {
                            workflowHeader(workflow)
                            if let dynamic = workflow.dynamic {
                                dynamicPreview(dynamic, workflowID: workflow.id)
                            } else {
                                ForEach(workflow.phases) { phase in
                                    WorkflowPhaseRow(
                                        phase: phase,
                                        totalChildren: workflow.plan?.phases
                                            .first(where: { $0.sequence == phase.sequence })?
                                            .childInstructions.count
                                            ?? phase.childRunIDs.count,
                                        childInstructions: workflow.plan?.phases
                                            .first(where: { $0.sequence == phase.sequence })?
                                            .childInstructions ?? []
                                    )
                                }
                            }
                        }
                    }
                }
                #if os(iOS)
                .listStyle(.insetGrouped)
                #else
                .listStyle(.inset)
                #endif
                .scrollContentBackground(.hidden)
                .background(Theme.bg)
            }
        }
        .navigationTitle("Workflow")
    }

    private func workflowHeader(_ workflow: WorkflowSummary) -> some View {
        HStack(alignment: .center, spacing: Theme.Space.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(workflow.title)
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                Text(workflow.dynamic.map {
                    $0.state.displayLabel(
                        attached: store?.executingWorkflowIDs.contains(workflow.id) == true
                    )
                } ?? workflow.status.label)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .accessibilityIdentifier("workflow.state")
            }
            Spacer(minLength: 0)
            if workflow.dynamic == nil && workflow.status == .running
                && store?.executingWorkflowIDs.contains(workflow.id) != true
            {
                Button {
                    Task { await store?.resume(workflowID: workflow.id) }
                } label: {
                    if store?.resumingWorkflowIDs.contains(workflow.id) == true {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Resume", systemImage: "play.fill")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(store?.resumeHandler == nil
                    || store?.resumingWorkflowIDs.contains(workflow.id) == true)
                .accessibilityIdentifier("workflow.resume")
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func dynamicPreview(_ dynamic: DynamicWorkflowPresentation, workflowID: UUID) -> some View {
        if let metadata = dynamic.metadata {
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                Text(metadata.description)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                if !metadata.phases.isEmpty {
                    Text("Phases")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.textTertiary)
                    ForEach(Array(metadata.phases.enumerated()), id: \.offset) { index, phase in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(index + 1). \(phase.title)")
                                .font(.subheadline.weight(.medium))
                            if let detail = phase.detail, !detail.isEmpty {
                                Text(detail).font(.caption).foregroundStyle(Theme.textSecondary)
                            }
                        }
                    }
                }
            }
        }
        if let source = dynamic.source {
            DisclosureGroup("JavaScript source") {
                ScrollView(.horizontal) {
                    Text(source)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .padding(.vertical, Theme.Space.xs)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Workflow JavaScript source")
                .accessibilityValue(source)
                .accessibilityIdentifier("workflow.source")
            }
        }
        if dynamic.currentPhase != nil || dynamic.totalCallCount > 0 || !dynamic.logs.isEmpty {
            DisclosureGroup("Runtime activity") {
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    if let phase = dynamic.currentPhase {
                        Label(phase, systemImage: "flag.fill")
                            .font(.caption.weight(.medium))
                    }
                    if dynamic.totalCallCount > 0 {
                        Text("\(dynamic.completedCallCount) of \(dynamic.totalCallCount) agents completed")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    ForEach(Array(dynamic.logs.suffix(20).enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.caption.monospaced())
                            .foregroundStyle(Theme.textSecondary)
                            .textSelection(.enabled)
                    }
                }
                .accessibilityIdentifier("workflow.activity")
            }
        }
        if let childCalls = dynamic.childCalls, !childCalls.isEmpty {
            DisclosureGroup("Agent calls") {
                VStack(alignment: .leading, spacing: Theme.Space.sm) {
                    ForEach(childCalls) { call in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Image(systemName: call.status.symbol)
                                    .foregroundStyle(call.status.color)
                                Text(call.label ?? "Agent \(call.ordinal)")
                                    .font(.caption.weight(.semibold))
                                Spacer()
                                Text("Attempt \(call.attempt) · \(call.status.label)")
                                    .font(.caption2)
                                    .foregroundStyle(Theme.textTertiary)
                            }
                            if let phase = call.phase {
                                Text(phase).font(.caption2).foregroundStyle(Theme.textSecondary)
                            }
                            if let detail = call.detail {
                                Text(detail).font(.caption2).foregroundStyle(Theme.textSecondary)
                            }
                            if canRestart(call, in: dynamic.state) {
                                Button("Restart agent", systemImage: "arrow.clockwise") {
                                    Task {
                                        await store?.restartDynamic(
                                            workflowID: workflowID,
                                            callID: call.callID
                                        )
                                    }
                                }
                                .font(.caption)
                                .disabled(store?.actioningWorkflowIDs.contains(workflowID) == true)
                                .accessibilityIdentifier("workflow.agent.restart")
                            }
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("workflow.agent.call")
                    }
                }
            }
            .accessibilityValue(
                (["\(childCalls.count) calls"] + childCalls.map { call in
                    let name = call.label ?? "Agent \(call.ordinal)"
                    let phase = call.phase.map { " · \($0)" } ?? ""
                    let detail = call.detail.map { " · \($0)" } ?? ""
                    return "\(call.ordinal). \(name) · attempt \(call.attempt) · "
                        + "\(call.status.label)\(phase)\(detail)"
                }).joined(separator: "\n")
            )
            .accessibilityIdentifier("workflow.agent.calls")
        }
        if let failure = dynamic.failure {
            Label(failure, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(Theme.danger)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(failure)
                .accessibilityIdentifier("workflow.failure")
        }
        dynamicActions(
            dynamic.state,
            workflowID: workflowID,
            attached: store?.executingWorkflowIDs.contains(workflowID) == true
        )
    }

    @ViewBuilder
    private func dynamicActions(
        _ state: DynamicWorkflowPresentationState,
        workflowID: UUID,
        attached: Bool
    ) -> some View {
        let busy = store?.actioningWorkflowIDs.contains(workflowID) == true
        switch state {
        case .waitingForLaunchApproval:
            HStack {
                Button("Run workflow", systemImage: "play.fill") {
                    Task { await store?.runDynamic(workflowID: workflowID) }
                }
                .buttonStyle(.borderedProminent)
                Button("Cancel", role: .destructive) {
                    Task { await store?.denyDynamic(workflowID: workflowID) }
                }
            }
            .disabled(busy)
            .accessibilityIdentifier("workflow.run")
        case .queued:
            Button("Start", systemImage: "play.fill") {
                Task { await store?.startDynamic(workflowID: workflowID) }
            }
            .buttonStyle(.borderedProminent)
            .disabled(busy)
            .accessibilityIdentifier("workflow.start")
        case .running where !attached:
            HStack {
                Button("Resume", systemImage: "play.fill") {
                    Task { await store?.resumeDynamic(workflowID: workflowID) }
                }
                .buttonStyle(.borderedProminent)
                Button("Stop", role: .destructive) {
                    Task { await store?.stopDynamic(workflowID: workflowID) }
                }
            }
            .disabled(busy)
            .accessibilityIdentifier("workflow.interrupted")
        case .running, .pausing:
            HStack {
                Button("Pause", systemImage: "pause.fill") {
                    Task { await store?.pauseDynamic(workflowID: workflowID) }
                }
                Button("Stop", role: .destructive) {
                    Task { await store?.stopDynamic(workflowID: workflowID) }
                }
            }.disabled(busy || state == .pausing)
        case .paused, .waitingForForeground:
            HStack {
                Button("Resume", systemImage: "play.fill") {
                    Task { await store?.resumeDynamic(workflowID: workflowID) }
                }
                Button("Stop", role: .destructive) {
                    Task { await store?.stopDynamic(workflowID: workflowID) }
                }
            }.disabled(busy)
        case .waitingForReconciliation:
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                Text("Confirm what happened to the uncertain external action before continuing.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                HStack {
                    Button("Succeeded") {
                        Task {
                            await store?.reconcileDynamic(
                                workflowID: workflowID,
                                decision: .succeeded
                            )
                        }
                    }
                    Button("Did not happen") {
                        Task {
                            await store?.reconcileDynamic(
                                workflowID: workflowID,
                                decision: .failed
                            )
                        }
                    }
                    Button("Abandon", role: .destructive) {
                        Task {
                            await store?.reconcileDynamic(
                                workflowID: workflowID,
                                decision: .abandoned
                            )
                        }
                    }
                }
            }
            .disabled(busy)
            .accessibilityIdentifier("workflow.reconciliation")
        default:
            EmptyView()
        }
    }

    private func canRestart(
        _ call: DynamicWorkflowChildPresentation,
        in state: DynamicWorkflowPresentationState
    ) -> Bool {
        guard state == .paused || state == .waitingForReconciliation else { return false }
        return [.failed, .unavailable, .stopped, .uncertain].contains(call.status)
    }
}

/// One phase node in the workflow tree.
struct WorkflowPhaseRow: View {
    let phase: WorkflowPhaseRecord
    let totalChildren: Int
    let childInstructions: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: Theme.Space.xs) {
                Image(systemName: phase.status.symbol)
                    .font(.caption)
                    .foregroundStyle(phase.status.color)
                    .accessibilityHidden(true)
                Text(phase.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                if let endTime = phase.endTime, let startTime = phase.startTime {
                    Text(Format.duration(endTime.timeIntervalSince(startTime)))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            Text("\(phase.status.label) · \(phase.completedChildCount)/\(totalChildren) subagents · "
                 + Format.shortCount(phase.stats.inputTokens + phase.stats.outputTokens)
                 + " tokens · \(phase.stats.toolInvocationCount) tool calls")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
            if !phase.acceptanceCriteria.isEmpty {
                Text("Accept: \(phase.acceptanceCriteria)")
                    .font(.caption2)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(2)
            }
            if !childInstructions.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(childInstructions.enumerated()), id: \.offset) { index, instruction in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: childStatus(index).symbol)
                                .font(.caption2)
                                .foregroundStyle(childStatus(index).color)
                                .accessibilityHidden(true)
                            Text(instruction)
                                .font(.caption2)
                                .foregroundStyle(Theme.textSecondary)
                                .lineLimit(2)
                        }
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private func childStatus(_ index: Int) -> (symbol: String, color: Color) {
        if index < phase.completedChildCount {
            return ("checkmark.circle.fill", Theme.fitGreen)
        }
        if index == phase.completedChildCount, phase.status == .running {
            return ("arrow.triangle.2.circlepath", Theme.accent)
        }
        return ("circle", Theme.textTertiary)
    }
}

private extension WorkflowStatus {
    var label: String {
        switch self {
        case .running: "Running"
        case .completed: "Completed"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        }
    }
}

private extension WorkflowPhaseStatus {
    var label: String {
        switch self {
        case .pending: "Pending"
        case .running: "Running"
        case .waiting: "Waiting"
        case .completed: "Completed"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        }
    }

    var symbol: String {
        switch self {
        case .pending: "circle"
        case .running: "arrow.triangle.2.circlepath"
        case .waiting: "hourglass"
        case .completed: "checkmark.circle.fill"
        case .failed: "xmark.octagon.fill"
        case .cancelled: "minus.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .pending: Theme.textTertiary
        case .running: Theme.accent
        case .waiting: Theme.textSecondary
        case .completed: Theme.fitGreen
        case .failed: Theme.danger
        case .cancelled: Theme.textTertiary
        }
    }
}

private extension DynamicWorkflowPresentationState {
    var label: String { displayLabel(attached: true) }

    func displayLabel(attached: Bool) -> String {
        switch self {
        case .generatingCandidate: "Generating candidate"
        case .waitingForLaunchApproval: "Ready to run"
        case .queued: "Approved — ready to start"
        case .running: attached ? "Running" : "Interrupted — Resume to continue"
        case .pausing: "Pausing"
        case .paused: "Paused"
        case .waitingForForeground: "Waiting for foreground"
        case .waitingForReconciliation: "Needs reconciliation"
        case .completed: "Completed"
        case .failed: "Failed"
        case .cancelled: "Denied or stopped"
        }
    }
}

private extension DynamicWorkflowChildStatus {
    var label: String {
        switch self {
        case .prepared: "Prepared"
        case .submitted: "Running"
        case .completed: "Completed"
        case .failed: "Failed"
        case .unavailable: "Unavailable"
        case .stopped: "Stopped"
        case .uncertain: "Needs reconciliation"
        }
    }

    var symbol: String {
        switch self {
        case .prepared: "circle"
        case .submitted: "arrow.triangle.2.circlepath"
        case .completed: "checkmark.circle.fill"
        case .failed: "xmark.octagon.fill"
        case .unavailable: "exclamationmark.triangle.fill"
        case .stopped: "stop.circle.fill"
        case .uncertain: "questionmark.diamond.fill"
        }
    }

    var color: Color {
        switch self {
        case .prepared: Theme.textTertiary
        case .submitted: Theme.accent
        case .completed: Theme.fitGreen
        case .failed, .unavailable, .uncertain: Theme.danger
        case .stopped: Theme.textSecondary
        }
    }
}
