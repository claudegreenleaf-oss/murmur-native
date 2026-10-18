import Foundation
import FluidAudio

/// Parakeet TDT v3 (multilingual) on the Neural Engine via FluidAudio. Models live in
/// ~/Library/Application Support/Murmur/models/. Loaded when a dictation starts, released after an idle period.
actor ASREngine {
    static let modelName = "parakeet-tdt-0.6b-v3"

    private var manager: AsrManager?
    private var loading: Task<AsrManager, Error>?
    private(set) var lastError: String?
    private let idle = IdleUnloader()
    private var inFlight = 0

    static func modelsDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let root = base.appendingPathComponent("Murmur", isDirectory: true)
            .appendingPathComponent("models", isDirectory: true)
        // The downloader derives the repo folder from the target directory's name.
        let folder = AsrModels.defaultCacheDirectory(for: .v3).lastPathComponent
        return root.appendingPathComponent(folder, isDirectory: true)
    }

    var isLoaded: Bool { manager != nil }

    func warm() async {
        do { _ = try await ensureLoaded() } catch {
            lastError = "\(error)"
            elog("ASR warm-up failed: \(error)")
        }
    }

    /// Releases the models (Core ML / ANE memory). Returns false while loading or transcribing.
    func unloadIfIdle() async -> Bool {
        if inFlight > 0 || loading != nil { return false }
        guard let m = manager else { return true }
        manager = nil
        await m.cleanup()
        elog("Parakeet unloaded after idle")
        return true
    }

    private func ensureLoaded() async throws -> AsrManager {
        idle.touch { [weak self] in await self?.unloadIfIdle() ?? true }
        if let m = manager { return m }
        if let l = loading { return try await l.value }
        let t = Task { () throws -> AsrManager in
            let dir = ASREngine.modelsDirectory()
            try FileManager.default.createDirectory(
                at: dir.deletingLastPathComponent(), withIntermediateDirectories: true)
            elog("loading Parakeet v3 from \(dir.path) (downloads on first use)")
            let models = try await AsrModels.downloadAndLoad(to: dir, version: .v3)
            let m = AsrManager(config: .default)
            try await m.loadModels(models)
            elog("Parakeet v3 ready")
            return m
        }
        loading = t
        do {
            let m = try await t.value
            manager = m
            loading = nil
            lastError = nil
            return m
        } catch {
            loading = nil
            lastError = "\(error)"
            throw error
        }
    }

    /// Transcribes 16 kHz mono float samples. Returns "" on failure or silence.
    func transcribe(_ samples: [Float], language: String?) async -> String {
        guard !samples.isEmpty else { return "" }
        inFlight += 1
        defer { inFlight -= 1; idle.touch { [weak self] in await self?.unloadIfIdle() ?? true } }
        do {
            let m = try await ensureLoaded()
            var audio = samples
            let minSamples = ASRConstants.minimumRequiredSamples(forSampleRate: 16_000)
            if audio.count < minSamples {
                audio += [Float](repeating: 0, count: minSamples - audio.count)
            }
            var state = TdtDecoderState.make(decoderLayers: await m.decoderLayerCount)
            let hint: Language? = language.flatMap { Language(rawValue: $0) }
            let result = try await m.transcribe(audio, decoderState: &state, language: hint)
            return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            elog("transcribe failed: \(error)")
            return ""
        }
    }
}

/// Post-ASR vocabulary handling. FluidAudio's CTC keyword boosting needs a second model
/// download, so this is a conservative fuzzy correction against the user's terms.
enum VocabCorrector {
    static func applyReplacements(_ text: String, _ replacements: [String: String]) -> String {
        var out = text
        for (wrong, right) in replacements where !wrong.isEmpty {
            let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: wrong) + "(?![\\p{L}\\p{N}])"
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            out = re.stringByReplacingMatches(
                in: out, range: NSRange(out.startIndex..., in: out),
                withTemplate: NSRegularExpression.escapedTemplate(for: right))
        }
        return out
    }

    private static func norm(_ s: String) -> String {
        String(s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    static func levenshtein(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        for i in 1...a.count {
            var cur = [i] + [Int](repeating: 0, count: b.count)
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
            }
            prev = cur
        }
        return prev[b.count]
    }

    static func correct(_ text: String, vocabulary: [String]) -> String {
        let terms = vocabulary.map { (term: $0, key: norm($0), words: $0.split(separator: " ").count) }
            .filter { $0.key.count >= 4 }
        if terms.isEmpty || text.isEmpty { return text }

        var tokens = text.components(separatedBy: " ")
        var i = 0
        var out: [String] = []
        while i < tokens.count {
            var replaced = false
            for t in terms {
                for width in Set([t.words, t.words + 1, max(1, t.words - 1)]).sorted(by: >) {
                    if i + width > tokens.count { continue }
                    let window = Array(tokens[i..<(i + width)])
                    let core = window.map { norm($0) }.joined()
                    if core.count < 4 || core == t.key && window.joined(separator: " ").contains(t.term) { continue }
                    if core.first != t.key.first { continue }
                    let dist = levenshtein(Array(core), Array(t.key))
                    let allowed = t.key.count >= 8 ? 2 : 1
                    // Same letters differing only by case/spacing also lands here with dist 0.
                    if dist <= allowed && abs(core.count - t.key.count) <= allowed {
                        let lead = String(window.first!.prefix(while: { !$0.isLetter && !$0.isNumber }))
                        let trail = String(window.last!.reversed().prefix(while: { !$0.isLetter && !$0.isNumber }).reversed())
                        out.append(lead + t.term + trail)
                        i += width
                        replaced = true
                        break
                    }
                }
                if replaced { break }
            }
            if !replaced {
                out.append(tokens[i])
                i += 1
            }
        }
        tokens = out
        return tokens.joined(separator: " ")
    }
}
