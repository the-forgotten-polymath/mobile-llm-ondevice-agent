// SPDX-License-Identifier: MIT

import Foundation
import XCTest
import AgentContracts
import LLMCore
@testable import AgentRuntime

final class LocalModelRegistryGrowthTests: XCTestCase {
    func testNewModelIsAvailableWithoutReplacingFrozenRegistrations() async throws {
        let model = LLMCatalog.bonsai8b
        let version = SemanticVersion("1.0.0")!
        let initial = try LocalModelRegistration(providerID: AgentModelProviderID("local.initial"),
            capabilityVersion: version, model: model, variant: model.defaultVariantValue,
            weightsDirectory: URL(fileURLWithPath: "/tmp/initial"))
        let adopted = try LocalModelRegistration(providerID: AgentModelProviderID("local.adopted"),
            capabilityVersion: version, model: model, variant: model.defaultVariantValue,
            weightsDirectory: URL(fileURLWithPath: "/tmp/adopted"))
        let engine = LocalAdapterScriptedEngine()
        let driver = try LLMCoreModelResidencyDriver(engine: engine, registrations: [initial])
        let catalog = try StaticAgentModelProviderCatalog(providers: [])
        let coordinator = LocalModelRegistrationCoordinator(catalog: catalog, driver: driver)
        try await coordinator.register(initial)
        async let a: Void = coordinator.register(adopted)
        async let b: Void = coordinator.register(adopted)
        _ = try await (a, b)
        let provider = try catalog.provider(for: adopted.selection)
        let capabilities = try await provider.capabilities(for: adopted.selection)
        XCTAssertEqual(capabilities, adopted.capabilities)
        try await driver.load(selection: adopted.selection)
        let resident = await driver.currentResidentSelection
        XCTAssertEqual(resident, adopted.selection)
        let changed = try LocalModelRegistration(providerID: adopted.selection.providerID,
            capabilityVersion: version, model: model, variant: model.defaultVariantValue,
            weightsDirectory: URL(fileURLWithPath: "/tmp/replaced"))
        do { try await coordinator.register(changed); XCTFail("frozen identity must not change") }
        catch LocalModelAdapterError.duplicateSelection { }
        let retained = try await driver.registration(for: adopted.selection)
        XCTAssertEqual(retained, adopted)
    }
}
