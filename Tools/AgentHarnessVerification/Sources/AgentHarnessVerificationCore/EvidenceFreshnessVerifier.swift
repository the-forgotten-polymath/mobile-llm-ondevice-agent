// SPDX-License-Identifier: MIT

import Foundation

public struct EvidenceFreshnessConfiguration: Sendable {
    public let expectedSourceCommit: String
    public let expectedSpecSHA256: String
    public let reportURLs: [URL]
    public let requiredScopes: Set<String>

    public init(
        expectedSourceCommit: String,
        expectedSpecSHA256: String,
        reportURLs: [URL],
        requiredScopes: Set<String> = ["AgentContracts", "AgentRuntime", "AgentSandboxAPI"]
    ) {
        self.expectedSourceCommit = expectedSourceCommit
        self.expectedSpecSHA256 = expectedSpecSHA256
        self.reportURLs = reportURLs.map(\.standardizedFileURL)
        self.requiredScopes = requiredScopes
    }
}

public enum AgentHarnessEvidenceFreshnessVerifier {
    public static func verify(_ configuration: EvidenceFreshnessConfiguration) -> VerificationReport {
        var diagnostics: [VerificationDiagnostic] = []
        func add(_ code: String, _ location: String, _ message: String) {
            diagnostics.append(.init(code: code, location: location, message: message))
        }
        guard configuration.expectedSourceCommit.range(
            of: "^[a-f0-9]{40}$", options: .regularExpression
        ) != nil else {
            add("AHV-EVIDENCE-SOURCE-COMMIT", "expectedSourceCommit", "expected commit is not 40 lowercase hex")
            return VerificationReport(diagnostics: diagnostics)
        }
        guard configuration.expectedSpecSHA256.range(
            of: "^[a-f0-9]{64}$", options: .regularExpression
        ) != nil else {
            add("AHV-EVIDENCE-SPEC-DIGEST", "expectedSpecSHA256", "expected spec digest is not 64 lowercase hex")
            return VerificationReport(diagnostics: diagnostics)
        }
        var observedScopes: Set<String> = []
        var observedPaths: Set<String> = []
        for url in configuration.reportURLs {
            let location = url.path
            if !observedPaths.insert(location).inserted {
                add("AHV-EVIDENCE-DUPLICATE-REPORT", location, "report path is duplicated")
                continue
            }
            guard let data = try? Data(contentsOf: url), !data.isEmpty,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                add("AHV-EVIDENCE-REPORT-DECODE", location, "coverage report is missing or invalid JSON")
                continue
            }
            guard object["schemaVersion"] as? Int == 1,
                  object["documentType"] as? String == "agent-harness-coverage-report",
                  let scope = object["scope"] as? String,
                  let inputs = object["inputs"] as? [String: Any]
            else {
                add("AHV-EVIDENCE-REPORT-SHAPE", location, "report identity or inputs are missing")
                continue
            }
            if !observedScopes.insert(scope).inserted {
                add("AHV-EVIDENCE-DUPLICATE-SCOPE", scope, "scope has more than one report")
            }
            if object["succeeded"] as? Bool != true {
                add("AHV-EVIDENCE-FAILED-REPORT", scope, "only successful reports may enter evidence")
            }
            if inputs["sourceCommit"] as? String != configuration.expectedSourceCommit {
                add("AHV-EVIDENCE-STALE-COMMIT", scope, "report was not produced from the expected source commit")
            }
            if inputs["specSHA256"] as? String != configuration.expectedSpecSHA256 {
                add("AHV-EVIDENCE-STALE-SPEC", scope, "report was not produced against the expected specification")
            }
            if inputs["sourceTreeStatus"] as? String != "clean" {
                add("AHV-EVIDENCE-DIRTY-TREE", scope, "dirty-tree diagnostics cannot satisfy CI/release evidence")
            }
            for digestField in ["xunitSHA256", "changedDiffSHA256"] {
                guard let digest = inputs[digestField] as? String,
                      digest.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil
                else {
                    add("AHV-EVIDENCE-INPUT-DIGEST", "\(scope).\(digestField)", "input digest is missing or invalid")
                    continue
                }
            }
        }
        let missing = configuration.requiredScopes.subtracting(observedScopes)
        let unexpected = observedScopes.subtracting(configuration.requiredScopes)
        if !missing.isEmpty {
            add("AHV-EVIDENCE-MISSING-SCOPE", "reports", "missing scopes: \(missing.sorted().joined(separator: ", "))")
        }
        if !unexpected.isEmpty {
            add("AHV-EVIDENCE-UNEXPECTED-SCOPE", "reports", "unexpected scopes: \(unexpected.sorted().joined(separator: ", "))")
        }
        return VerificationReport(diagnostics: diagnostics)
    }
}
