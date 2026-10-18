import Foundation
import MLX
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

/// Why the formatter declined to load (or to run). Not a load failure: the model stays "available" and the
/// dictation falls back to Apple FM or the rules.
private struct FormatterDeclined: Error, CustomStringConvertible {
    let description: String
}

/// Memory facts the formatter uses to decide whether it is safe to hold a model.
enum MemoryGuard {
    /// kern.memorystatus_vm_pressure_level: 1 normal, 2 warning, 4 critical. Unreadable counts as normal.
    static var pressureLevel: Int {
        var v: Int32 = 1
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &v, &size, nil, 0) != 0 { return 1 }
        return Int(v)
    }

    /// Bytes the system could hand out without swapping: free + inactive + purgeable + speculative pages.
    /// The kernel's free_count already includes the speculative pages (vm_stat prints free minus speculative),
    /// so they are counted once. Returns nil when the statistics call fails.
    static var availableBytes: Int? {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        let pages = Int(stats.free_count) + Int(stats.inactive_count) + Int(stats.purgeable_count)
        return pages * Int(getpagesize())
    }

    /// This process's physical footprint (what Activity Monitor and the jetsam accounting call memory), in bytes.
    static var footprintBytes: Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Int(info.phys_footprint) : 0
    }

    static func mb(_ bytes: Int) -> Int { bytes / (1024 * 1024) }

    /// "footprint 1234 MB (mlx active 1100, cache 40, peak 1300)" for the log.
    static var summary: String {
        "footprint \(mb(footprintBytes)) MB (mlx active \(mb(Memory.activeMemory)), cache \(mb(Memory.cacheMemory)), peak \(mb(Memory.peakMemory)))"
    }
}

/// Local distilled formatter: an mlx-lm converted (4-bit) Qwen3 (any size, same chat template) in
/// ~/Library/Application Support/Murmur/models/formatter-mlx. Loaded lazily when a local dictation starts
/// and only when the Mac has the memory for it, unloaded after an idle period (see IdleUnloader) or at once
/// on a kernel memory-pressure warning; requests are serialized and decoded greedily.
final class MLXFormatter: @unchecked Sendable {
    static let shared = MLXFormatter()

    static let modelDirectory: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Murmur/models/formatter-mlx", isDirectory: true)

    /// Free memory that must remain beyond the weights before a load is admitted.
    static let admissionHeadroom = 1536 * 1024 * 1024
    /// MLX may allocate this much beyond the weights (KV cache, activations, cached buffers) before it blocks.
    static let runtimeHeadroom = 768 * 1024 * 1024
    /// Longest prompt (system + user, in tokens) sent to the model; longer ones use the fallback.
    static let maxPromptTokens = 3000

    private let lock = NSLock()
    private var loadTask: Task<ModelContainer, Error>?
    private var loaded = false
    private var failed = false
    private var busy = false
    private var pendingUnload = false
    private var epoch = 0
    private var lastDeclineLog: (reason: String, at: Date)?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private let idle = IdleUnloader()
    private var pressureSource: DispatchSourceMemoryPressure?

    private init() {
        let src = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .global(qos: .userInitiated))
        src.setEventHandler { [weak self] in
            guard let self = self else { return }
            let level = src.data.contains(.critical) ? "critical" : "warning"
            elog("memory pressure \(level): unloading MLX formatter")
            _ = self.unload("memory pressure \(level)", deferIfBusy: true)
        }
        src.resume()
        pressureSource = src
    }

    /// True when a model directory is installed and has not failed to load (loaded or not).
    static var isAvailable: Bool { shared.available }
    /// True once the model is resident in memory.
    static var isLoaded: Bool { shared.isResident }

    static func respond(system: String, user: String, maxTokens: Int) async throws -> String {
        try await shared.generate(system: system, user: user, maxTokens: maxTokens)
    }

    /// Starts loading in the background (no-op when absent, already loading, or the Mac is short of memory)
    /// and runs one tiny generation so the dictation does not pay for kernel compilation. Call when a local
    /// dictation begins.
    static func prepare() { shared.prepareInBackground() }

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

    /// On-disk size of everything in the model directory; the resident weights are about this big.
    private static func modelBytes() -> Int {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: modelDirectory, includingPropertiesForKeys: [.fileSizeKey], options: []) else { return 0 }
        return files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    /// Throws FormatterDeclined unless the kernel is at normal pressure and enough memory is free.
    private func admit(modelBytes: Int) throws {
        let level = MemoryGuard.pressureLevel
        if level != 1 {
            throw FormatterDeclined(description: "memory pressure level \(level) (need 1)")
        }
        let need = modelBytes + Self.admissionHeadroom
        if let avail = MemoryGuard.availableBytes, avail < need {
            throw FormatterDeclined(
                description: "available memory \(MemoryGuard.mb(avail)) MB < model \(MemoryGuard.mb(modelBytes)) MB + 1536 MB headroom")
        }
    }

    private func logDeclined(_ reason: String) {
        lock.lock()
        let repeatLog = lastDeclineLog.map { $0.reason == reason && Date().timeIntervalSince($0.at) < 30 } ?? false
        if !repeatLog { lastDeclineLog = (reason, Date()) }
        lock.unlock()
        if !repeatLog { elog("MLX formatter not loaded: \(reason); using fallback") }
    }

    /// Returns the load task and the epoch it belongs to, starting a load only if admission passes.
    private func loadTaskLocked() throws -> (Task<ModelContainer, Error>, Int) {
        lock.lock(); defer { lock.unlock() }
        if let t = loadTask { return (t, epoch) }
        let dir = Self.modelDirectory
        let bytes = Self.modelBytes()
        try admit(modelBytes: bytes)
        let t = Task.detached(priority: .utility) { () -> ModelContainer in
            // Keep freed buffers from being hoarded by MLX's allocator cache, and stop MLX from growing
            // past the weights plus a fixed working-set allowance.
            Memory.cacheLimit = 64 * 1024 * 1024
            Memory.memoryLimit = bytes + Self.runtimeHeadroom
            return try await loadModelContainer(from: dir, using: LocalTokenizerLoader())
        }
        loadTask = t
        return (t, epoch)
    }

    private func markFailed() { lock.lock(); failed = true; lock.unlock() }

    private func container() async throws -> ModelContainer {
        idle.touch { [self] in unloadIfIdle() }
        do {
            let (task, myEpoch) = try loadTaskLocked()
            let c = try await task.value
            lock.lock()
            let stale = myEpoch != epoch
            let first = !loaded && !stale
            if !stale { loaded = true }
            lock.unlock()
            if stale { throw FormatterDeclined(description: "unloaded while loading") }
            if first {
                elog("MLX formatter loaded, \(MemoryGuard.summary)")
            }
            return c
        } catch let d as FormatterDeclined {
            logDeclined(d.description)
            throw d
        } catch is CancellationError {
            // A pressure unload abandoned the load; the model is still installed, so do not mark it failed.
            logDeclined("load cancelled")
            throw FormatterDeclined(description: "load cancelled")
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
            let pending = pendingUnload
            lock.unlock()
            // A memory-pressure unload arrived mid-generation: it runs now that the generation is done.
            if pending { _ = unload("memory pressure (after in-flight generation)", deferIfBusy: false) }
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
        // A pressure unload may have landed while this request waited for the lock.
        lock.lock(); let resident = loaded; lock.unlock()
        if !resident { throw FormatterDeclined(description: "unloaded before generation") }
        // Long prompts cost KV cache and prefill activations; send them to the fallback instead.
        let promptTokens = await model.tokenizer.encode(text: system + "\n" + user, addSpecialTokens: false).count
        if promptTokens > Self.maxPromptTokens {
            throw FormatterDeclined(description: "prompt \(promptTokens) tokens > \(Self.maxPromptTokens)")
        }
        // A fresh session per request keeps dictations independent (no carried chat history or KV state).
        let session = ChatSession(
            model, instructions: system,
            generateParameters: GenerateParameters(
                maxTokens: maxTokens, maxKVSize: promptTokens + maxTokens + 64, temperature: 0),
            additionalContext: ["enable_thinking": false])
        let out = try await session.respond(to: user)
        idle.touch { [self] in unloadIfIdle() }
        elog("MLX generation done (\(promptTokens) prompt tokens), \(MemoryGuard.summary)")
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

    private func prepareInBackground() {
        guard available else { return }
        idle.touch { [self] in unloadIfIdle() }
        Task.detached(priority: .utility) { [self] in
            let t0 = Date()
            let was = isResident
            _ = try? await generate(system: "Reply with one word.", user: "hello", maxTokens: 4)
            if !was && isResident { elog("MLX formatter ready in \(Int(Date().timeIntervalSince(t0) * 1000)) ms") }
        }
    }

    private func unloadIfIdle() -> Bool {
        unload("after idle", deferIfBusy: false)
    }

    /// Releases the model and MLX's buffer cache. Returns false when a generation is in flight; with
    /// `deferIfBusy` the unload then runs as soon as that generation finishes. Also abandons a load in progress.
    private func unload(_ reason: String, deferIfBusy: Bool) -> Bool {
        lock.lock()
        if busy {
            if deferIfBusy { pendingUnload = true }
            lock.unlock()
            return false
        }
        pendingUnload = false
        let had = loaded || loadTask != nil
        loadTask?.cancel()
        loadTask = nil
        loaded = false
        epoch += 1
        lock.unlock()
        guard had else { return true }
        Memory.clearCache()
        elog("MLX formatter unloaded (\(reason)), \(MemoryGuard.summary)")
        // The finishing generation may still hold the container; clear again once it has let go.
        Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            Memory.clearCache()
        }
        return true
    }
}
