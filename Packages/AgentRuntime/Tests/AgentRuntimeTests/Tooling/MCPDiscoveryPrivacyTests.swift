// SPDX-License-Identifier: MIT

import Foundation
import XCTest
import LLMCore
@testable import AgentRuntime

final class MCPDiscoveryPrivacyTests: XCTestCase {
    func testCacheScrubsLegacyAndNewCredentialsAndResolvesCurrentKey() throws {
        let suite = "MCPDiscoveryPrivacyTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = "mobilellm.mcpDiscovery.v1"
        let server = MCPServer(name: "fixture", url: "https://fixture.test/mcp", token: "legacy-secret")
        struct LegacyEntry: Encodable { let server: MCPServer; let specs: [MCPToolSpec] }
        defaults.set(try JSONEncoder().encode([
            server.stableID.uuidString: LegacyEntry(server: server, specs: [])
        ]), forKey: key)
        let cache = MCPDiscoveryCache(defaults: defaults, credentialResolver: { _ in "current-key" })
        XCTAssertFalse(String(decoding: defaults.data(forKey: key)!, as: UTF8.self).contains("legacy-secret"))
        cache.update(server: server, specs: [])
        cache.upsert(server: server)
        let snapshot = String(decoding: defaults.data(forKey: key)!, as: UTF8.self)
        XCTAssertFalse(snapshot.contains("legacy-secret"))
        XCTAssertFalse(snapshot.contains("current-key"))
        XCTAssertEqual(cache.server(serverStableID: server.stableID)?.token, "current-key")
        cache.setCredentialResolver { _ in nil }
        XCTAssertNil(cache.server(serverStableID: server.stableID)?.token)
        cache.removeAll()
        XCTAssertNil(defaults.data(forKey: key))
        XCTAssertNil(cache.server(serverStableID: server.stableID))
    }

    func testEndpointEditRequiresDiscoveryAgain() {
        let suite = "MCPDiscoveryPrivacyTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let cache = MCPDiscoveryCache(defaults: defaults)
        var server = MCPServer(name: "fixture", url: "https://first.test/mcp")
        cache.update(server: server, specs: [MCPToolSpec(name: "lookup", description: "read", inputSchemaJSON: "{}")])
        server.url = "https://second.test/mcp"
        XCTAssertTrue(cache.descriptors(for: [server]).isEmpty)
        cache.upsert(server: server)
        XCTAssertTrue(cache.specs(serverStableID: server.stableID).isEmpty)
    }
}
