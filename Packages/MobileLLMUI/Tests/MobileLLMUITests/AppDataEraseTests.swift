// SPDX-License-Identifier: MIT

import XCTest
import AgentRuntime
import AppRuntime
@testable import LLMCore
@testable import MobileLLMUI

@MainActor
final class AppDataEraseTests: XCTestCase {
    private var root: URL!
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(component: "app-erase-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        suite = "AppDataEraseTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    private func makeContainer(memoryStore: (any MemoryStoring)? = nil,
                               credentials: any OpenAICredentialStoring = EphemeralOpenAICredentialStore(),
                               cache: MCPDiscoveryCache? = nil) -> AppContainer {
        let settings = AppSettings(defaults: defaults, fallbackDefaultModelID: "bonsai-8b", keychain: nil)
        return AppContainer(
            engine: MockLLMEngine(),
            downloadBase: root.appending(component: "downloads"),
            downloader: { _, _, _, progress in progress(1) },
            settings: settings,
            conversationStore: ConversationStore(directory: root.appending(component: "conversations")),
            memoryStore: memoryStore,
            installProbe: { _, _ in false },
            availableMemory: { .max },
            openAICredentials: credentials,
            mcpDiscovery: cache ?? MCPDiscoveryCache(defaults: defaults)
        )
    }

    func testEraseAllAppDataCoversEveryAppOwnedScope() async throws {
        let container = makeContainer()
        try await container.skills.load()
        _ = try await container.skills.create(name: "Private custom skill", emoji: "🔐",
                                               summary: "", instructions: "secret instructions")
        try await container.memory.add("The user is named Dong.")

        let image = ImageRef()
        try await container.conversationStore.writeAttachment(Data("pixels".utf8), id: image.id)
        let conversation = Conversation(
            title: "Private chat",
            modelID: "bonsai-8b",
            variantID: LLMCatalog.bonsai8b.defaultVariantValue.id,
            messages: [Message(role: .user, answer: "secret", attachments: [image])]
        )
        try await container.conversationStore.save(conversation)

        let downloadBase = root.appending(component: "downloads")
        let modelSentinel = downloadBase.appending(component: "models/acme/private/weights.gguf")
        try FileManager.default.createDirectory(at: modelSentinel.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("weights".utf8).write(to: modelSentinel)
        let outsideModelRoot = downloadBase.appending(component: "do-not-delete.txt")
        try Data("outside models root".utf8).write(to: outsideModelRoot)
        let registryURL = downloadBase.appending(component: "adopted-models.json")
        try await DurableStore<LLMModel>(fileURL: registryURL).save([LLMCatalog.bonsai8b])
        let corruptRegistryURL = registryURL.appendingPathExtension("corrupt")
        try Data("private adopted model metadata".utf8).write(to: corruptRegistryURL)

        container.settings.systemPrompt = "private prompt"
        container.settings.toolsEnabled = true
        container.settings.mcpServers = [
            MCPServer(name: "Private", url: "https://mcp.example.test", token: "secret-token")
        ]

        try await container.eraseAllAppData()

        let remainingChats = await container.conversationStore.loadAllLive()
        let remainingAttachment = await container.conversationStore.attachmentData(image.id)
        let remainingRegistry = await DurableStore<LLMModel>(fileURL: registryURL).load()
        XCTAssertTrue(remainingChats.isEmpty)
        XCTAssertNil(remainingAttachment)
        XCTAssertTrue(container.memory.facts.isEmpty)
        XCTAssertTrue(container.skills.customSkills.isEmpty)
        XCTAssertEqual(container.skills.skills, Skill.builtIns)
        XCTAssertFalse(FileManager.default.fileExists(atPath: downloadBase.appending(component: "models").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outsideModelRoot.path),
                      "model erasure is confined to downloadBase/models")
        XCTAssertTrue(remainingRegistry.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: corruptRegistryURL.path),
                       "erase-all must remove DurableStore's forensic adopted-model backup too")
        XCTAssertNil(container.models.active)
        XCTAssertEqual(container.settings.systemPrompt, SystemPrompt.standard)
        XCTAssertFalse(container.settings.toolsEnabled)
        XCTAssertTrue(container.settings.mcpServers.isEmpty)

        let relaunched = AppSettings(defaults: defaults, fallbackDefaultModelID: "bonsai-8b", keychain: nil)
        XCTAssertEqual(relaunched.systemPrompt, SystemPrompt.standard)
        XCTAssertFalse(relaunched.toolsEnabled)
        XCTAssertTrue(relaunched.mcpServers.isEmpty)
    }

    func testFullEraseIncludesRuntimeCacheCredentialsAndOnlineSelection() async throws {
        let credentials = EphemeralOpenAICredentialStore()
        let cache = MCPDiscoveryCache(defaults: defaults)
        let container = makeContainer(credentials: credentials, cache: cache)
        let directory = container.conversationStore.directory
        let runtime = directory.appending(component: "agent")
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
        try Data("private input".utf8).write(to: runtime.appending(component: "journal.sqlite"))
        try Data("[]".utf8).write(to: directory.appending(component: "workflows.json"))
        let service = OnlineService(id: "fixture", name: "fixture", baseURL: "https://fixture.test", isEnabled: true)
        container.settings.upsertOnlineService(service)
        try credentials.saveAPIKey("fixture-secret", serviceID: service.id)
        cache.update(server: MCPServer(name: "fixture", url: "https://fixture.test/mcp", token: "fixture-mcp"), specs: [])
        try await container.eraseAllAppData()
        XCTAssertFalse(FileManager.default.fileExists(atPath: runtime.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appending(component: "workflows.json").path))
        XCTAssertNil(try credentials.loadAPIKey(serviceID: service.id))
        XCTAssertTrue(container.settings.onlineServices.isEmpty)
        XCTAssertNil(defaults.data(forKey: "mobilellm.mcpDiscovery.v1"))
        XCTAssertFalse(container.hasPendingDataErase)
    }

    func testInterruptedEraseResumesBeforeBootstrapCanOpenRuntime() async throws {
        let failed = makeContainer(memoryStore: DeleteFailingMemoryStore())
        do { try await failed.eraseAllAppData(); XCTFail("injected failure") } catch { }
        XCTAssertTrue(failed.hasPendingDataErase)
        let recovered = makeContainer()
        var runtimeOpened = false
        recovered.runtimeBootstrap = {
            XCTAssertFalse(recovered.hasPendingDataErase)
            runtimeOpened = true
        }
        await recovered.bootstrap()
        XCTAssertTrue(runtimeOpened)
        XCTAssertFalse(recovered.hasPendingDataErase)
    }

    func testRuntimeDrainFailureNeverDeletesLiveDataOrClearsIntent() async throws {
        let container = makeContainer()
        let conversation = Conversation(modelID: "bonsai-8b", variantID: "fixture")
        try await container.conversationStore.save(conversation)
        container.prepareRuntimeDataErase = { throw ConversationEraseInProgressError() }
        do { try await container.deleteAllChats(); XCTFail("drain failure") } catch { }
        let retained = await container.conversationStore.load(conversation.id)
        XCTAssertNotNil(retained)
        XCTAssertTrue(container.hasPendingDataErase)
        container.prepareRuntimeDataErase = nil
        try await container.resumePendingDataErase()
        XCTAssertFalse(container.hasPendingDataErase)
    }

    func testEraseAggregatesFailureAndStillAttemptsOtherScopes() async throws {
        let container = makeContainer(memoryStore: DeleteFailingMemoryStore())
        let conversation = Conversation(modelID: "bonsai-8b", variantID: "variant")
        try await container.conversationStore.save(conversation)
        let modelsRoot = root.appending(component: "downloads/models/acme/model")
        try FileManager.default.createDirectory(at: modelsRoot, withIntermediateDirectories: true)
        container.settings.toolsEnabled = true

        do {
            try await container.eraseAllAppData()
            XCTFail("the injected memory failure must be reported")
        } catch let error as AppDataEraseError {
            XCTAssertTrue(error.failures.contains { $0.hasPrefix("Memory:") })
        }

        let remainingChats = await container.conversationStore.loadAllLive()
        XCTAssertTrue(remainingChats.isEmpty,
                      "one failed scope must not prevent chats from being erased")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appending(component: "downloads/models").path),
                       "one failed scope must not prevent model data from being erased")
        XCTAssertFalse(container.settings.toolsEnabled,
                       "one failed scope must not prevent settings from being reset")
    }
}

private actor DeleteFailingMemoryStore: MemoryStoring {
    private struct InjectedFailure: LocalizedError {
        var errorDescription: String? { "Injected memory erase failure" }
    }

    func save(_ text: String, source: MemoryFact.Source) -> MemoryFact {
        MemoryFact(text: text, source: source)
    }
    func saveIfAbsent(_ text: String, source: MemoryFact.Source) -> MemorySaveResult {
        .saved(MemoryFact(text: text, source: source))
    }
    func list() -> [MemoryFact] { [] }
    func update(id: String, text: String) {}
    func delete(id: String) {}
    func deleteAll() throws { throw InjectedFailure() }
}
