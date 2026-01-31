// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import AgentHarnessVerificationCore

final class EvidenceFreshnessVerifierTests: XCTestCase {
    // TEST-ID: AHT-INFRA-007
    func testAcceptsOneCleanSuccessfulReportPerRequiredScopeFromSameSource() throws {
        let fixture = try FreshnessFixture()
        let report = AgentHarnessEvidenceFreshnessVerifier.verify(fixture.configuration())
        XCTAssertTrue(report.succeeded, report.diagnostics.map(\.message).joined(separator: "\n"))
    }

    func testRejectsStaleDirtyFailedDuplicateMissingAndUndigestedReports() throws {
        let fixture = try FreshnessFixture()
        var stale = try fixture.object(scope: "AgentContracts")
        stale["succeeded"] = false
        var inputs = stale["inputs"] as! [String: Any]
        inputs["sourceCommit"] = String(repeating: "c", count: 40)
        inputs["specSHA256"] = String(repeating: "d", count: 64)
        inputs["sourceTreeStatus"] = "dirty"
        inputs.removeValue(forKey: "xunitSHA256")
        stale["inputs"] = inputs
        try fixture.write(stale, to: fixture.urls[0])

        let configuration = EvidenceFreshnessConfiguration(
            expectedSourceCommit: fixture.commit,
            expectedSpecSHA256: fixture.spec,
            reportURLs: [fixture.urls[0], fixture.urls[0], fixture.urls[1]],
            requiredScopes: ["AgentContracts", "AgentRuntime", "AgentSandboxAPI"]
        )
        let codes = Set(AgentHarnessEvidenceFreshnessVerifier.verify(configuration).diagnostics.map(\.code))
        XCTAssertTrue(codes.contains("AHV-EVIDENCE-FAILED-REPORT"))
        XCTAssertTrue(codes.contains("AHV-EVIDENCE-STALE-COMMIT"))
        XCTAssertTrue(codes.contains("AHV-EVIDENCE-STALE-SPEC"))
        XCTAssertTrue(codes.contains("AHV-EVIDENCE-DIRTY-TREE"))
        XCTAssertTrue(codes.contains("AHV-EVIDENCE-INPUT-DIGEST"))
        XCTAssertTrue(codes.contains("AHV-EVIDENCE-DUPLICATE-REPORT"))
        XCTAssertTrue(codes.contains("AHV-EVIDENCE-MISSING-SCOPE"))
    }
}

private final class FreshnessFixture {
    let root: URL
    let commit = String(repeating: "a", count: 40)
    let spec = String(repeating: "b", count: 64)
    let urls: [URL]

    init() throws {
        let fixtureRoot = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        root = fixtureRoot
        try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
        urls = ["AgentContracts", "AgentRuntime", "AgentSandboxAPI"].map {
            fixtureRoot.appending(path: "\($0).json")
        }
        for (scope, url) in zip(["AgentContracts", "AgentRuntime", "AgentSandboxAPI"], urls) {
            try write(object(scope: scope), to: url)
        }
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func configuration() -> EvidenceFreshnessConfiguration {
        EvidenceFreshnessConfiguration(
            expectedSourceCommit: commit,
            expectedSpecSHA256: spec,
            reportURLs: urls
        )
    }

    func object(scope: String) throws -> [String: Any] {
        [
            "schemaVersion": 1,
            "documentType": "agent-harness-coverage-report",
            "scope": scope,
            "succeeded": true,
            "inputs": [
                "sourceCommit": commit,
                "specSHA256": spec,
                "sourceTreeStatus": "clean",
                "xunitSHA256": String(repeating: "e", count: 64),
                "changedDiffSHA256": String(repeating: "f", count: 64),
            ],
        ]
    }

    func write(_ object: [String: Any], to url: URL) throws {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: url)
    }
}
