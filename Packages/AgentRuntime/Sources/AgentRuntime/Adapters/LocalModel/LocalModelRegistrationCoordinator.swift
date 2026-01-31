// SPDX-License-Identifier: MIT

import AgentContracts

/// Serializes registry growth without replacing any model/provider already frozen into a run.
public actor LocalModelRegistrationCoordinator {
    private let catalog: StaticAgentModelProviderCatalog
    private let driver: LLMCoreModelResidencyDriver
    private let artifactResolver: any LocalModelArtifactBytesResolving

    public init(catalog: StaticAgentModelProviderCatalog, driver: LLMCoreModelResidencyDriver,
                artifactResolver: any LocalModelArtifactBytesResolving = UnavailableLocalModelArtifactResolver()) {
        self.catalog = catalog
        self.driver = driver
        self.artifactResolver = artifactResolver
    }

    public func register(_ registration: LocalModelRegistration) async throws {
        _ = try await driver.register(registration)
        if (try? catalog.provider(for: registration.selection)) != nil { return }
        try catalog.register(LocalModelProvider(
            descriptor: AgentModelProviderDescriptor(id: registration.selection.providerID,
                adapterVersion: registration.selection.capabilityVersion,
                capabilityVersion: registration.selection.capabilityVersion, location: .onDevice),
            residencyDriver: driver, artifactResolver: artifactResolver, registration: registration
        ))
    }
}
