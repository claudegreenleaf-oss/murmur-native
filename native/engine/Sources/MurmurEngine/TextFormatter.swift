import Foundation

struct FormatOutcome {
    var status = "formatted"          // formatted | raw_transcript | empty
    var plaintext = ""
    var html = ""
    var skipReason = ""
    var formatMs = 0
    var startsWithProperNoun = false
    var llmModel = ""                 // model that produced the text, empty when rules did
    var deletions = 0
    var substitutions = 0
}

/// Raw transcript in, final text out. Mirrors shared/prompts/format-request.md.
final class TextFormatter: @unchecked Sendable {
    private let lock = NSLock()
    private var hasSucceeded = false

    private func markSuccess() { lock.lock(); hasSucceeded = true; lock.unlock() }
    private var timeout: Double {
        lock.lock(); defer { lock.unlock() }
        // The very first call may still be loading the on-device model.
        return hasSucceeded ? 4.0 : 10.0
    }

    private func style(_ ini: InitInfo, _ ctx: ContextInfo) -> String {
        let category = Prompts.shared.styleCategory[ctx.appType] ?? "other"
        return ini.generalStyle[category] ?? "formal"
    }

    func run(raw: String, ini: InitInfo, ctx: ContextInfo, instruction: String? = nil) async -> FormatOutcome {
        let started = Date()
        var out = FormatOutcome()

        var transcript = VocabCorrector.applyReplacements(raw, ini.replacements)
        transcript = VocabCorrector.correct(transcript, vocabulary: ini.vocabulary)
        transcript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)

        if transcript.isEmpty {
            out.status = "empty"
            out.skipReason = "empty_transcript"
            return out
        }

        if let exp = PostProcess.wholeUtteranceSnippet(transcript, ini.snippets) {
            out.plaintext = exp
            return finish(out, raw: raw, ini: ini, ctx: ctx, started: started)
        }

        var text = transcript
        let styleName = style(ini, ctx)

        if ini.format == "none" {
            out.status = "raw_transcript"
            out.skipReason = "client_disabled"
        } else {
            let (formatted, reason, model) = await llmFormat(transcript: transcript, ini: ini, ctx: ctx, instruction: instruction)
            if let f = formatted {
                text = f
                out.status = "formatted"
                out.llmModel = model
            } else {
                let cleaned = RuleCleanup.clean(transcript, style: styleName, format: ini.format)
                out.skipReason = reason
                if cleaned.isEmpty && reason == "formatter_empty_output" {
                    out.status = "empty"
                } else {
                    out.status = "raw_transcript"
                }
                text = cleaned
            }
        }

        text = PostProcess.applySnippets(text, ini.snippets)
        if ini.format == "all_lowercase" {
            text = text.lowercased()
        } else if ini.format == "casual_messaging" {
            let nouns = PostProcess.properNounSet(ini: ini, ctx: ctx, transcript: transcript)
            text = PostProcess.lowercaseSentenceStarts(text, properNouns: nouns)
        }
        out.plaintext = text
        return finish(out, raw: raw, ini: ini, ctx: ctx, started: started)
    }

    private func finish(_ o: FormatOutcome, raw: String, ini: InitInfo, ctx: ContextInfo, started: Date) -> FormatOutcome {
        var out = o
        out.html = PostProcess.toHTML(out.plaintext)
        out.startsWithProperNoun = PostProcess.startsWithProperNoun(out.plaintext, ini: ini, ctx: ctx)
        let s = PostProcess.editStats(raw: raw, finalText: out.plaintext)
        out.deletions = s.deletions
        out.substitutions = s.substitutions
        out.formatMs = Int(Date().timeIntervalSince(started) * 1000)
        return out
    }

    /// Returns (text, "", model) on success or (nil, skipReason, "") when the caller should fall back.
    private func llmFormat(transcript: String, ini: InitInfo, ctx: ContextInfo, instruction: String?) async -> (String?, String, String) {
        // The distilled MLX model takes the student prompt, which has no slot for an extra instruction.
        // While it is still loading, Apple Foundation Models (when present) covers the first dictations.
        if MLXFormatter.isAvailable && (MLXFormatter.isLoaded || !AppleLLM.isAvailable) && (instruction ?? "").isEmpty {
            let r = await mlxFormat(transcript: transcript, ini: ini, ctx: ctx)
            if r.0 != nil || !AppleLLM.isAvailable || r.1 != "formatter_error" { return r }
            // The MLX model failed to load or run: fall back to Apple Foundation Models.
        }
        guard AppleLLM.isAvailable else { return (nil, "formatter_error", "") }
        let system = Prompts.shared.systemMessage(ini: ini, ctx: ctx, instruction: instruction, compact: true)
        let prompt: String = Prompts.userMessage(transcript)
        let approxTokens = Int(Double(PostProcess.words(transcript).count) * 1.5) + 8
        let maxTokens = min(2 * approxTokens + 64, 2000)
        do {
            let t = timeout
            let raw = try await race(timeout: t) {
                try await AppleLLM.respond(instructions: system, prompt: prompt, maxTokens: maxTokens)
            }
            markSuccess()
            return guarded(raw, transcript: transcript, ini: ini, model: "apple-foundation-models")
        } catch is RaceTimeout {
            return (nil, "formatter_timeout", "")
        } catch {
            elog("formatter error: \(error)")
            return (nil, "formatter_error", "")
        }
    }

    private func mlxFormat(transcript: String, ini: InitInfo, ctx: ContextInfo) async -> (String?, String, String) {
        let system = Prompts.shared.studentSystemMessage(ini: ini, ctx: ctx)
        let prompt = Prompts.studentUserMessage(transcript)
        let approxTokens = Int(Double(PostProcess.words(transcript).count) * 1.5) + 8
        let maxTokens = min(2 * approxTokens + 64, 2000)
        do {
            let t = timeout
            let raw = try await race(timeout: t) {
                try await MLXFormatter.respond(system: system, user: prompt, maxTokens: maxTokens)
            }
            markSuccess()
            return guarded(raw, transcript: transcript, ini: ini, model: "murmur-formatter-mlx")
        } catch is RaceTimeout {
            return (nil, "formatter_timeout", "")
        } catch {
            elog("mlx formatter error: \(error)")
            return (nil, "formatter_error", "")
        }
    }

    /// Shared output guards for both models.
    private func guarded(_ raw: String, transcript: String, ini: InitInfo, model: String) -> (String?, String, String) {
        let cleaned = PostProcess.stripEchoes(raw)
        if cleaned.isEmpty { return (nil, "formatter_empty_output", "") }
        if PostProcess.looksHallucinated(output: cleaned, transcript: transcript, strength: ini.editingStrength) {
            return (nil, "formatter_hallucination", "")
        }
        return (cleaned, "", model)
    }

    // MARK: Command mode

    /// Applies a spoken instruction to selected text. Throws when the model is unavailable.
    func runCommand(instruction: String, selected: String, ctx: ContextInfo) async throws -> String {
        guard AppleLLM.isAvailable else { throw LLMError.unavailable }
        var built = "INSTRUCTION:\n<<<\n\(instruction)\n>>>\nSELECTED TEXT:\n<<<\n\(String(selected.prefix(6000)))\n>>>"
        if !ctx.appName.isEmpty { built += "\nAPP: \(ctx.appName) (\(ctx.bundleId))" }
        let prompt = built
        let system = Prompts.shared.commandSystem
        let maxTokens = min(Int(Double(PostProcess.words(selected).count) * 3) + 256, 2500)
        let raw = try await race(timeout: 20) {
            try await AppleLLM.respond(instructions: system, prompt: prompt, maxTokens: maxTokens)
        }
        let cleaned = PostProcess.stripEchoes(raw)
        if cleaned.isEmpty { throw LLMError.empty }
        return cleaned
    }

    // MARK: Auto-learn validation

    func extractEditedWords(potential: [String], candidates: [(word: String, source: String)], source: String) async -> [(String, String)] {
        guard AppleLLM.isAvailable, !candidates.isEmpty else { return [] }
        let payload: JSON = [
            "source": source,
            "potential_words": potential,
            "candidates": candidates.map { ["word": $0.word, "observed_source": $0.source] },
        ]
        let prompt = encodeJSONString(payload)
        let system = Prompts.shared.extractSystem
        do {
            let raw = try await race(timeout: 15) {
                try await AppleLLM.respond(instructions: system, prompt: prompt, maxTokens: 600)
            }
            guard let a = raw.firstIndex(of: "{"), let b = raw.lastIndex(of: "}"), a < b,
                  let obj = parseJSON(Data(raw[a...b].utf8)),
                  let arr = obj["accepted_candidates"] as? [Any] else { return [] }
            let allowed = Set(candidates.map { $0.word + "\u{0}" + $0.source })
            var out: [(String, String)] = []
            for item in arr {
                guard let d = item as? JSON else { continue }
                let w = d.str("word"), s = d.str("observed_source")
                if allowed.contains(w + "\u{0}" + s) { out.append((w, s)) }
            }
            return out
        } catch {
            elog("extract_edited_words error: \(error)")
            return []
        }
    }
}
