// SPDX-License-Identifier: MIT

import AgentContracts
import Foundation

/// Persists small bridge values inline and larger values in the existing verified artifact store.
/// The event journal always receives an immutable content-addressed reference, never an absolute
/// path. Artifact ownership is tied to the durable workflow run so normal retention can collect it.
public struct ContentAddressedWorkflowValueStore: WorkflowValueStoring, Sendable {
    public static let defaultInlineThreshold = 64 * 1_024

    private let store: ContentAddressedArtifactStore
    private let inlineThreshold: Int

    public init(
        store: ContentAddressedArtifactStore,
        inlineThreshold: Int = Self.defaultInlineThreshold
    ) throws {
        guard inlineThreshold >= 0, inlineThreshold <= CanonicalJSON.maximumBytes else {
            throw AgentContractError.wireLimitExceeded("workflow inline value threshold")
        }
        self.store = store
        self.inlineThreshold = inlineThreshold
    }

    public func store(
        _ value: CanonicalJSON,
        runID: WorkflowRunID
    ) async throws -> WorkflowValueReferenceV1 {
        guard value.data.count > inlineThreshold else { return .inline(value) }
        let owner = ArtifactOwner.workflowRun(runID)
        let provenance = try ArtifactProvenance(
            workflowRunID: runID,
            providerID: "mobilellm.dynamic-workflow"
        )
        let reference = try await store.commit(ArtifactCommitRequest(
            data: value.data,
            expectedDigest: value.fingerprint,
            expectedByteCount: UInt64(value.data.count),
            mimeType: "application/json",
            semanticType: "dynamic-workflow-value.v1",
            provenance: provenance,
            retentionPolicy: .run,
            sensitivity: .sensitive,
            initialOwner: owner
        ))
        return .artifact(reference)
    }

    public func load(_ reference: WorkflowValueReferenceV1) async throws -> CanonicalJSON {
        switch reference {
        case .inline(let value):
            return value
        case .artifact(let artifact):
            guard artifact.mimeType == "application/json",
                  artifact.semanticType == "dynamic-workflow-value.v1",
                  artifact.byteCount <= UInt64(CanonicalJSON.maximumBytes)
            else { throw DynamicWorkflowEngineError.outputUnavailable }
            let data = try await store.data(
                for: artifact,
                maximumBytes: UInt64(CanonicalJSON.maximumBytes)
            )
            return try CanonicalJSON(canonicalData: data)
        }
    }
}
