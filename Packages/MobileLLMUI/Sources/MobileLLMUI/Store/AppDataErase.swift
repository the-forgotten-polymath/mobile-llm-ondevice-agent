// SPDX-License-Identifier: MIT

import Foundation

public struct AppDataEraseError: LocalizedError, Sendable {
    public let failures: [String]
    public var errorDescription: String? {
        "Some app data could not be erased:\n" + failures.map { "• \($0)" }.joined(separator: "\n")
    }
}

private struct AppEraseIntent: Codable {
    var allData: Bool
    var serviceIDs: [String]
}

public extension AppContainer {
    /// Outside every store being erased; survives process loss without containing user content.
    var dataEraseMarkerURL: URL { conversationStore.directory.appendingPathExtension("erase-pending") }
    var hasPendingDataErase: Bool { FileManager.default.fileExists(atPath: dataEraseMarkerURL.path) }

    func deleteAllChats() async throws {
        try await beginDataErase(allData: false)
        if runtimeBootstrap != nil { await bootstrap() }
    }
    func eraseAllAppData() async throws {
        try await beginDataErase(allData: true)
        if runtimeBootstrap != nil { await bootstrap() }
    }

    /// Bootstrap calls this before opening the runtime or hydrating any user store.
    func resumePendingDataErase() async throws {
        guard hasPendingDataErase else { return }
        let intent = try JSONDecoder().decode(AppEraseIntent.self, from: Data(contentsOf: dataEraseMarkerURL))
        try await performDataErase(intent)
    }

    private func beginDataErase(allData: Bool) async throws {
        guard !isErasingData else { throw AppDataEraseError(failures: ["Another erase is in progress."]) }
        var intent = AppEraseIntent(allData: allData, serviceIDs: settings.onlineServices.map(\.id))
        if hasPendingDataErase {
            let previous = try JSONDecoder().decode(AppEraseIntent.self, from: Data(contentsOf: dataEraseMarkerURL))
            intent.allData = allData || previous.allData
            intent.serviceIDs = Array(Set(intent.serviceIDs + previous.serviceIDs)).sorted()
        }
        try FileManager.default.createDirectory(at: dataEraseMarkerURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        #if os(iOS)
        try JSONEncoder().encode(intent).write(to: dataEraseMarkerURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try JSONEncoder().encode(intent).write(to: dataEraseMarkerURL, options: .atomic)
        #endif
        var marker = dataEraseMarkerURL
        var attributes = URLResourceValues()
        attributes.isExcludedFromBackup = true
        try marker.setResourceValues(attributes)
        try await performDataErase(intent)
    }

    private func performDataErase(_ intent: AppEraseIntent) async throws {
        guard !isErasingData else { throw AppDataEraseError(failures: ["Another erase is in progress."]) }
        isErasingData = true
        defer { isErasingData = false }
        chat.setAcceptingNewActions(false)
        await chat.quiesceForConversationErase()
        var conversationsErased = false
        defer { chat.finishConversationErase(succeeded: conversationsErased, resetSessionState: intent.allData) }
        // If a producer cannot drain, leave the marker and data intact; no writer may race removal.
        try await prepareRuntimeDataErase?()
        await outboxProjector?.suspendAndDrain()
        await agentRuns?.discardAllForDataErase()
        var failures: [String] = []
        do {
            if let eraseRuntimeData { try await eraseRuntimeData() }
            else {
                let agent = conversationStore.directory.appending(component: "agent")
                if FileManager.default.fileExists(atPath: agent.path) { try FileManager.default.removeItem(at: agent) }
            }
            try workflowStore.eraseAllData()
        } catch { failures.append("Agent runs and workflows: \(error.localizedDescription)") }
        do {
            try await conversationStore.deleteAll()
            conversationsErased = true
        } catch { failures.append("Chats and attachments: \(error.localizedDescription)") }
        if intent.allData {
            do { try await models.eraseDownloadedData() }
            catch { failures.append("Models: \(error.localizedDescription)") }
            syncActive()
            do { try await memory.deleteAll() }
            catch { failures.append("Memory: \(error.localizedDescription)") }
            do { try await skills.resetForDataErase() }
            catch { failures.append("Skills: \(error.localizedDescription)") }
            do { try openAICredentials.deleteAllAPIKeys(serviceIDs: intent.serviceIDs) }
            catch { failures.append("Online credentials: \(error.localizedDescription)") }
            mcpDiscovery.removeAll()
            do { try settings.resetForDataErase() }
            catch { failures.append("Settings and MCP credentials: \(error.localizedDescription)") }
        }
        guard failures.isEmpty else { throw AppDataEraseError(failures: failures) }
        try FileManager.default.removeItem(at: dataEraseMarkerURL)
        await finishRuntimeDataErase?()
        await outboxProjector?.resume()
        chat.setAcceptingNewActions(true)
    }
}
