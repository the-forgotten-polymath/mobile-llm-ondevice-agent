// SPDX-License-Identifier: MIT

import AgentContracts
@testable import AgentRuntime
import Foundation
import XCTest

// TEST-ID: AHT-DYNAMIC-001

final class DynamicWorkflowStorageTests: XCTestCase {
    func testContentAddressedValueStoreMovesLargeCanonicalJSONOutOfJournalAndVerifiesRoundTrip() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("workflow-values-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let artifactStore = try ContentAddressedArtifactStore(configuration: ArtifactStoreConfiguration(
            rootURL: root,
            maximumArtifactBytes: UInt64(CanonicalJSON.maximumBytes),
            excludeFromBackup: false,
            verifyPlatformProtection: false
        ))
        let values = try ContentAddressedWorkflowValueStore(store: artifactStore, inlineThreshold: 16)
        let original = try CanonicalJSON(.object([
            "payload": .string(String(repeating: "v", count: 2_048))
        ]))

        let reference = try await values.store(original, runID: WorkflowRunID())
        guard case .artifact(let artifact) = reference else {
            return XCTFail("value above the inline threshold must be content-addressed")
        }
        XCTAssertEqual(artifact.contentDigest, original.fingerprint)
        XCTAssertEqual(artifact.semanticType, "dynamic-workflow-value.v1")
        let loaded = try await values.load(reference)
        XCTAssertEqual(loaded, original)
    }

    func testGeneratedCandidateMetadataMustExactlyMatchAnalyzedSourceBeforeSaving() async throws {
        let source = """
        export const meta = { name: 'source-name', description: 'Source description' };
        return 'ok';
        """
        let script = try WorkflowScriptV1(
            scriptID: WorkflowScriptID(),
            version: 1,
            source: source
        )
        let mismatched = SavedWorkflowScriptV1(
            script: script,
            metadata: try WorkflowScriptMetadataV1(
                name: "spoofed-name",
                description: "Source description"
            ),
            owner: .personal(StableDigest.sha256(Data("storage-test-owner".utf8))),
            createdAt: AgentTimestamp(rawValue: 1)
        )
        let engine = DynamicWorkflowEngine(
            journal: InMemoryDynamicWorkflowJournal(),
            runtime: JavaScriptCoreWorkflowRuntime(),
            spawner: DynamicWorkflowNullSpawner(),
            requestBuilder: ClosureWorkflowChildRequestBuilder { _, _, _ in
                throw DynamicWorkflowEngineError.outputUnavailable
            }
        )
        do {
            _ = try await engine.registerScript(mismatched)
            XCTFail("spoofed registry metadata must not be persisted")
        } catch let error as DynamicWorkflowEngineError {
            XCTAssertEqual(error, .scriptMetadataMismatch)
        }
        let saved = try await engine.savedScripts(owners: [mismatched.owner])
        XCTAssertTrue(saved.isEmpty)
    }

    func testSQLiteSavedScriptCatalogIsOwnerBoundAndLegacyOwnerlessPayloadFailsClosed() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("workflow-owner-catalog-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = SQLiteDynamicWorkflowJournal(
            databaseURL: directory.appendingPathComponent("workflows.sqlite3")
        )
        let source = "export const meta = { name: 'owned', description: 'Owned' }; return 'ok';"
        let ownerA = WorkflowScriptOwnerV1.conversation(ConversationID())
        let ownerB = WorkflowScriptOwnerV1.conversation(ConversationID())
        func saved(owner: WorkflowScriptOwnerV1) throws -> SavedWorkflowScriptV1 {
            let script = try WorkflowScriptV1(
                scriptID: WorkflowScriptID(), version: 1, source: source
            )
            return SavedWorkflowScriptV1(
                script: script,
                metadata: try WorkflowScriptMetadataV1(name: "owned", description: "Owned"),
                owner: owner,
                createdAt: AgentTimestamp(rawValue: 1)
            )
        }
        let savedA = try saved(owner: ownerA)
        let savedB = try saved(owner: ownerB)
        try await journal.saveScript(savedA)
        try await journal.saveScript(savedB)

        let loadedA = try await journal.loadScript(savedA.script.reference, owners: [ownerA])
        XCTAssertEqual(loadedA, savedA)
        let unrelated = try await journal.loadScript(savedA.script.reference, owners: [
            .conversation(ConversationID())
        ])
        XCTAssertNil(unrelated)
        let resolvedB = try await journal.resolveScript(named: "owned", owners: [ownerB])
        XCTAssertEqual(resolvedB, savedB)
        let listedA = try await journal.listScripts(owners: [ownerA])
        XCTAssertEqual(listedA, [savedA])

        var legacy = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(savedA)) as? [String: Any]
        )
        legacy.removeValue(forKey: "owner")
        let legacyData = try JSONSerialization.data(withJSONObject: legacy)
        XCTAssertThrowsError(try JSONDecoder().decode(SavedWorkflowScriptV1.self, from: legacyData))
    }
}

private actor DynamicWorkflowNullSpawner: SubagentSpawning {
    func spawn(_: SubagentSpawnRequest) throws -> AgentExecutionHandleID {
        throw DynamicWorkflowEngineError.outputUnavailable
    }

    func collect(_: AgentExecutionHandleID) throws -> SubagentResult {
        throw DynamicWorkflowEngineError.outputUnavailable
    }
}
