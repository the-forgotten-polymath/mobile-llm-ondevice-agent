// SPDX-License-Identifier: MIT

import AgentContracts
import Foundation
import LLMCore

/// Explicit MCP discovery results cached for the agent runtime.
///
/// Discovery (`initialize` + `tools/list`) runs ONLY from the user's server setup/refresh UI; prompt
/// compilation and run submission never connect to an MCP server (spec §13). The cache is the single
/// source of truth the agent catalog advertises, keyed by the server's stable random identity.
public final class MCPDiscoveryCache: @unchecked Sendable {
    /// The app-wide discovery cache: the settings UI is the only writer, the agent catalog the reader.
    public static let shared = MCPDiscoveryCache(defaults: .standard)

    private struct Entry: Codable {
        var server: MCPServer
        var specs: [MCPToolSpec]

        init(server: MCPServer, specs: [MCPToolSpec]) {
            self.server = server
            self.server.token = nil
            self.specs = specs
        }
    }

    private let lock = NSLock()
    private let defaults: UserDefaults
    private let persistenceKey: String
    private var entries: [UUID: Entry] = [:]
    private var epoch: UInt64 = 0

    public var generation: UInt64 {
        lock.lock(); defer { lock.unlock() }
        return epoch
    }
    private var credentialResolver: @Sendable (MCPServer) -> String?

    public init(
        defaults: UserDefaults = .standard,
        persistenceKey: String = "mobilellm.mcpDiscovery.v1",
        credentialResolver: @escaping @Sendable (MCPServer) -> String? = { _ in nil }
    ) {
        self.defaults = defaults
        self.persistenceKey = persistenceKey
        self.credentialResolver = credentialResolver
        if let data = defaults.data(forKey: persistenceKey),
           let decoded = try? JSONDecoder().decode([String: Entry].self, from: data)
        {
            self.entries = decoded.reduce(into: [:]) { result, pair in
                guard let stableID = UUID(uuidString: pair.key) else { return }
                result[stableID] = Entry(server: pair.value.server, specs: pair.value.specs)
            }
            // Retire plaintext tokens written by the old cache immediately on opening it.
            persistLocked()
        }
    }

    /// Credentials are resolved at invocation time and never become cache data.
    public func setCredentialResolver(_ resolver: @escaping @Sendable (MCPServer) -> String?) {
        lock.lock(); defer { lock.unlock() }
        credentialResolver = resolver
    }

    public func removeAll() {
        lock.lock(); defer { lock.unlock() }
        epoch &+= 1
        entries.removeAll()
        defaults.removeObject(forKey: persistenceKey)
    }

    public func update(server: MCPServer, specs: [MCPToolSpec]) {
        lock.lock(); defer { lock.unlock() }
        entries[server.stableID] = Entry(server: server, specs: specs)
        persistLocked()
    }

    /// Preserve discovered specs when a server's enable/mute settings change without re-probing.
    public func upsert(server: MCPServer) {
        lock.lock(); defer { lock.unlock() }
        let previous = entries[server.stableID]
        let specs = previous?.server.url == server.url ? previous?.specs ?? [] : []
        entries[server.stableID] = Entry(server: server, specs: specs)
        persistLocked()
    }

    public func remove(serverStableID: UUID) {
        lock.lock(); defer { lock.unlock() }
        entries[serverStableID] = nil
        persistLocked()
    }

    public func specs(serverStableID: UUID) -> [MCPToolSpec] {
        lock.lock(); defer { lock.unlock() }
        return entries[serverStableID]?.specs ?? []
    }

    /// The server snapshot at discovery time. The runtime calls the endpoint that was explicitly
    /// discovered; editing the URL requires an explicit re-test, so a changed URL cannot silently
    /// redirect previously approved operations.
    public func server(serverStableID: UUID) -> MCPServer? {
        lock.lock()
        var server = entries[serverStableID]?.server
        let resolver = credentialResolver
        lock.unlock()
        if let snapshot = server { server?.token = resolver(snapshot) }
        return server
    }

    /// The exact Tool V2 descriptors the runtime may advertise for the currently enabled servers.
    public func descriptors(
        for servers: [MCPServer],
        trustRevision: String = "mcp.v1"
    ) -> [AgentToolDescriptor] {
        lock.lock(); defer { lock.unlock() }
        var result: [AgentToolDescriptor] = []
        for server in servers
            where server.isEnabled && !server.url.trimmingCharacters(in: .whitespaces).isEmpty
        {
            guard let entry = entries[server.stableID], entry.server.url == server.url else { continue }
            let specs = entry.specs
            for spec in specs where !server.disabledTools.contains(spec.name) {
                guard let descriptor = try? MCPToolV2Adapter.descriptor(
                    spec: spec,
                    serverStableID: server.stableID,
                    trustRevision: trustRevision
                ) else { continue }
                result.append(descriptor)
            }
        }
        return result.sorted { $0.id.description < $1.id.description }
    }

    private func persistLocked() {
        let encoded = entries.reduce(into: [String: Entry]()) { result, pair in
            result[pair.key.uuidString] = pair.value
        }
        if let data = try? JSONEncoder().encode(encoded) {
            defaults.set(data, forKey: persistenceKey)
        }
    }
}
