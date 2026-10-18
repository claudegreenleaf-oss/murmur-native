import Foundation
import MLXLLM
import MLXLMCommon
import Tokenizers

/// Adapts swift-transformers' tokenizer to mlx-swift-lm's Tokenizer protocol (3.x no longer bundles one).
private struct TokenizerBridge: MLXLMCommon.Tokenizer {
    let upstream: any Tokenizers.Tokenizer

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? { upstream.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { upstream.convertIdToToken(id) }

    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    func applyChatTemplate(
        messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        do {
            return try upstream.applyChatTemplate(messages: messages, tools: tools, additionalContext: additionalContext)
        } catch Tokenizers.TokenizerError.missingChatTemplate {
            throw MLXLMCommon.TokenizerError.missingChatTemplate
        }
    }
}

private struct LocalTokenizerLoader: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        TokenizerBridge(upstream: try await AutoTokenizer.from(modelFolder: directory))
    }
}

/// Local distilled formatter: an mlx-lm converted (4-bit) Qwen3 in
/// ~/Library/Application Support/Murmur/models/formatter-mlx. Loaded once in the background and kept resident;
/// requests are serialized and decoded greedily.
final class MLXFormatter: @unchecked Sendable {
    static let shared = MLXFormatter()

    static let modelDirectory: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Murmur/models/formatter-mlx", isDirectory: true)

    private let lock = NSLock()
    private var loadTask: Task<ModelContainer, Error>?
    private var loaded = false
    private var failed = false
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// True when a model directory is installed and has not failed to load.
    static var isAvailable: Bool { shared.available }
    /// True once the model is resident in memory.
    static var isLoaded: Bool { shared.isResident }

    static func respond(system: String, user: String, maxTokens: Int) async throws -> String {
        try await shared.generate(system: system, user: user, maxTokens: maxTokens)
    }

    /// Loads the model and runs one tiny generation so the first dictation does not pay for kernel compilation.
    static func warmUp() async { await shared.warm() }

    private var available: Bool {
        lock.lock(); defer { lock.unlock() }
        if failed { return false }
        return FileManager.default.fileExists(
            atPath: Self.modelDirectory.appendingPathComponent("config.json").path)
    }

    private var isResident: Bool {
        lock.lock(); defer { lock.unlock() }
        return loaded
    }

    private func loadTaskLocked() -> Task<ModelContainer, Error> {
        lock.lock(); defer { lock.unlock() }
        if let t = loadTask { return t }
        let dir = Self.modelDirectory
        let t = Task.detached(priority: .utility) { () -> ModelContainer in
            try await loadModelContainer(from: dir, using: LocalTokenizerLoader())
        }
        loadTask = t
        return t
    }

    private func markLoaded() { lock.lock(); loaded = true; lock.unlock() }
    private func markFailed() { lock.lock(); failed = true; lock.unlock() }

    private func container() async throws -> ModelContainer {
        do {
            let c = try await loadTaskLocked().value
            markLoaded()
            return c
        } catch {
            markFailed()
            elog("MLX formatter load failed: \(error)")
            throw error
        }
    }

    /// FIFO mutex: one generation at a time (the GPU and the resident model are shared).
    private func acquire() async {
        let mustWait: Bool = {
            lock.lock(); defer { lock.unlock() }
            if busy { return true }
            busy = true
            return false
        }()
        if mustWait {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                lock.lock()
                // The holder may have released between the check and here.
                if !busy {
                    busy = true
                    lock.unlock()
                    c.resume()
                } else {
                    waiters.append(c)
                    lock.unlock()
                }
            }
        }
    }

    private func release() {
        lock.lock()
        if waiters.isEmpty {
            busy = false
            lock.unlock()
        } else {
            let next = waiters.removeFirst()
            lock.unlock()
            next.resume()  // busy stays true: ownership passes to the waiter
        }
    }

    private func generate(system: String, user: String, maxTokens: Int) async throws -> String {
        let model = try await container()
        await acquire()
        defer { release() }
        try Task.checkCancellation()
        // A fresh session per request keeps dictations independent (no carried chat history or KV state).
        let session = ChatSession(
            model, instructions: system,
            generateParameters: GenerateParameters(maxTokens: maxTokens, temperature: 0),
            additionalContext: ["enable_thinking": false])
        let out = try await session.respond(to: user)
        return Self.clean(out)
    }

    /// Drops an empty or stray reasoning block some Qwen3 templates emit before the answer.
    private static func clean(_ s: String) -> String {
        var t = s
        if let r = t.range(of: "<think>[\\s\\S]*?</think>", options: .regularExpression) {
            t.removeSubrange(r)
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func warm() async {
        guard available else { return }
        let t0 = Date()
        _ = try? await generate(system: "Reply with one word.", user: "hello", maxTokens: 4)
        if isResident { elog("MLX formatter ready in \(Int(Date().timeIntervalSince(t0) * 1000)) ms") }
    }
}
