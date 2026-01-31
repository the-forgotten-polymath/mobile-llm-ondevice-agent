// SPDX-License-Identifier: MIT

import Foundation
import CryptoKit
@_spi(AgentRuntime) import AgentContracts

/// Shared across retries. Only bounded chunks cross the gate; no response is accumulated first.
actor ResponsesAPIAccounting {
    private let emitter: AgentModelBoundaryEmitter
    private var hasher = SHA256()
    private var inputTokens: UInt64 = 0
    private var outputTokens: UInt64 = 0

    init(emitter: AgentModelBoundaryEmitter) { self.emitter = emitter }

    func consume(_ bytes: Data) async throws {
        try await emitter.accountResponseBytes(UInt64(bytes.count))
        hasher.update(data: bytes)
    }

    func record(_ usage: ResponsesAPIModelProvider.ParsedUsage) throws {
        let input = inputTokens.addingReportingOverflow(usage.inputTokens)
        let output = outputTokens.addingReportingOverflow(usage.outputTokens)
        guard !input.overflow, !output.overflow else {
            throw AgentContractError.invalidEventSequence("online usage overflow")
        }
        inputTokens = input.partialValue
        outputTokens = output.partialValue
    }

    var usage: ResponsesAPIModelProvider.ParsedUsage {
        .init(inputTokens: inputTokens, outputTokens: outputTokens)
    }

    var digest: StableDigest {
        get throws { try StableDigest(rawValue: hasher.finalize().map { String(format: "%02x", $0) }.joined()) }
    }
}

struct AccountedResponseBytes: AsyncSequence {
    typealias Element = UInt8
    let bytes: URLSession.AsyncBytes
    let accounting: ResponsesAPIAccounting

    struct AsyncIterator: AsyncIteratorProtocol {
        var source: URLSession.AsyncBytes.AsyncIterator
        let accounting: ResponsesAPIAccounting
        var pending = Data()

        mutating func next() async throws -> UInt8? {
            let byte = try await source.next()
            if let byte { pending.append(byte) }
            // Flush before a line can be parsed or a response can finish. Long/no-newline bodies
            // still cross the accounting gate at most 4 KiB apart.
            if byte == nil || byte == 10 || pending.count == 4_096 {
                if !pending.isEmpty { try await accounting.consume(pending); pending.removeAll(keepingCapacity: true) }
            }
            return byte
        }
    }

    func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(source: bytes.makeAsyncIterator(), accounting: accounting)
    }
}

final class ResponsesAPIRedirectBlocker: NSObject, URLSessionTaskDelegate, Sendable {
    static let shared = ResponsesAPIRedirectBlocker()

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
