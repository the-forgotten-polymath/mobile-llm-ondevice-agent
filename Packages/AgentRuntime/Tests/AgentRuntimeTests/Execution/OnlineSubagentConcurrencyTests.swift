// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@_spi(AgentRuntime) import AgentContracts
@testable import AgentRuntime

final class OnlineSubagentConcurrencyTests: XCTestCase {
    func testDurableChildrenOverlapActualProviderRequests() async throws {
        let model = try ExecutorTestModelDefinition(offset: 980, location: .remote,
            providerName: ResponsesAPIModelProvider.providerID)
        let destination = try ExternalDestination(kind: .modelProvider,
            normalizedIdentity: "openai.responses:responses-api-key:executor-test-model")
        let categories = [try AgentDataCategory(rawValue: "model.inference")]
        let ceiling = try RunCapabilityCeiling(authority: AgentAuthorityScope(
            capabilities: AgentCapabilitySet([.externalCommunication, .localRead]),
            destinations: [destination], dataCategories: categories))
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ConcurrentResponsesProtocol.self]
        let provider = try ResponsesAPIModelProvider(configuration: ResponsesAPIConfiguration(
            baseURL: "https://concurrency.test/v1", apiKey: "fixture-key"), session: URLSession(configuration: config))
        let harness = try ExecutorTestHarness(offset: 980, provider: provider, model: model,
            capabilityCeiling: ceiling, provenance: AgentRequestProvenance(source: .workflow),
            localOnly: false, approvalMode: .fullAccess)
        let root = try await harness.executor.submit(harness.request, commandID: ExecutorTestID.command(980))
        _ = try await collectTerminalEvents(from: harness.executor.attach(to: root))
        ConcurrentResponsesProtocol.counter.reset()
        let spawner = DurableSubagentSpawner(executor: harness.executor, repository: harness.repository)
        let childCeiling = try RunCapabilityCeiling(authority: AgentAuthorityScope(
            capabilities: AgentCapabilitySet([.externalCommunication]), destinations: [destination], dataCategories: categories))
        var values = Dictionary(uniqueKeysWithValues: BudgetDimension.allCases.map { ($0, harness.request.budget.limits[$0]) })
        values[.modelAttempts] = 2
        let budget = try AgentBudget(limits: BudgetQuantities(values),
            maximumThermalState: harness.request.budget.maximumThermalState,
            memoryPressureResponse: harness.request.budget.memoryPressureResponse)
        func child(_ offset: Int) throws -> SubagentSpawnRequest {
            try SubagentSpawnRequest(parentRunID: harness.request.runID, parentRequestID: harness.request.id,
                requestingStepID: AgentStepID(), childRunID: ExecutorTestID.run(offset), role: "research",
                instruction: "Answer", outputRequirement: .text, modelPolicy: harness.request.modelPolicy,
                capabilityCeiling: childCeiling, budget: budget, source: .workflow, approvalMode: .fullAccess)
        }
        let first = try await spawner.spawn(child(981))
        let second = try await spawner.spawn(child(982))
        async let a = spawner.collect(first)
        async let b = spawner.collect(second)
        let results = try await [a, b]
        for result in results {
            guard case .completed = result.outcome else { return XCTFail("child failed: \(result)") }
        }
        XCTAssertEqual(ConcurrentResponsesProtocol.counter.peak, 2,
            "measure simultaneous provider requests, not concurrent scheduler thunks")
    }
}

private final class RequestOverlap: @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0
    private var maximum = 0
    func reset() { lock.lock(); defer { lock.unlock() }; active = 0; maximum = 0 }
    func enter() { lock.lock(); defer { lock.unlock() }; active += 1; maximum = max(maximum, active) }
    func leave() { lock.lock(); defer { lock.unlock() }; active -= 1 }
    var peak: Int { lock.lock(); defer { lock.unlock() }; return maximum }
}

private final class ConcurrentResponsesProtocol: URLProtocol, @unchecked Sendable {
    static let counter = RequestOverlap()
    private let lock = NSLock()
    private var completed = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.counter.enter()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) { [self] in
            lock.lock()
            guard !completed else { lock.unlock(); return }
            completed = true
            lock.unlock()
            Self.counter.leave()
            let body = Data("data: {\"type\":\"response.output_text.delta\",\"delta\":\"done\"}\n\ndata: {\"type\":\"response.completed\",\"status\":\"completed\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}\n\n".utf8)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: ["Content-Type": "text/event-stream"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {
        lock.lock(); defer { lock.unlock() }
        if !completed { completed = true; Self.counter.leave() }
    }
}
