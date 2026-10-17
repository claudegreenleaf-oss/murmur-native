import Foundation

/// POST /v1/polish (shared/protocol/ENGINE.md). Prompt assembly is driven by polish-rules.json.
enum Polish {
    private static let system: String = {
        Prompts.text("polish-system", "txt").trimmingCharacters(in: CharacterSet(charactersIn: "\n"))
    }()
    private static let rules: JSON = {
        parseJSON(Data(Prompts.text("polish-rules", "json").utf8)) ?? [:]
    }()
    static let modelVersion = "apple-foundation-models"

    private static func reply(_ status: String, _ text: String? = nil) -> JSON {
        ["status": status, "polished_text": (text.map { $0 as Any } ?? NSNull() as Any), "model_version": modelVersion]
    }

    private static func squash(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private static func enabledLabels(_ instructions: JSON?) -> [String] {
        var out: [String] = []
        for group in ["default", "custom"] {
            guard let g = instructions?[group] as? JSON else { continue }
            for (label, on) in g {
                if let b = on as? Bool, b, !label.trimmingCharacters(in: .whitespaces).isEmpty {
                    out.append(label.trimmingCharacters(in: .whitespaces))
                }
            }
        }
        return out
    }

    static func buildSystem(_ body: JSON) -> String {
        let promptText = (body.obj("custom_prompt")?.str("prompt") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let toggles = rules.strMap("toggles")
        let mode: String
        let ruleText: String
        if !promptText.isEmpty {
            mode = rules.str("mode_custom")
            ruleText = rules.str("custom_header") + "\n" + promptText
        } else {
            mode = rules.str("mode_toggles")
            var lines = enabledLabels(body.obj("instructions")).map { toggles[$0] ?? (rules.str("extra_rule_prefix") + $0) }
            if lines.isEmpty, let d = toggles["Maintain your tone"] { lines = [d] }
            ruleText = rules.str("rules_header") + "\n" + lines.map { "- " + $0 }.joined(separator: "\n")
        }
        var voice: [String] = []
        let samples = body.strs("writing_samples")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if !samples.isEmpty {
            let block = samples.prefix(5).map { "<<<\n\($0)\n>>>" }.joined(separator: "\n")
            voice.append(rules.str("voice_block").replacingOccurrences(of: "{{SAMPLES}}", with: block))
        }
        let pref = body.str("user_voice_preference").trimmingCharacters(in: .whitespacesAndNewlines)
        if !pref.isEmpty {
            voice.append("\(samples.isEmpty ? 6 : 7). Voice preference from the user: \(pref)")
        }
        var out = system.replacingOccurrences(of: "{{MODE}}", with: mode)
            .replacingOccurrences(of: "{{RULES}}", with: ruleText)
            .replacingOccurrences(of: "{{VOICE}}", with: voice.joined(separator: "\n"))
        while out.last?.isWhitespace == true { out.removeLast() }
        out += "\n"
        if let app = body.obj("context")?.obj("app"), !app.str("name").isEmpty {
            out += "\nThe text was written in the app \(app.str("name"))."
        }
        return out
    }

    static func run(_ body: JSON) async -> JSON {
        let text = body.str("selected_text")
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return reply("no_text") }
        let wordCount = text.split(whereSeparator: { $0.isWhitespace }).count
        if wordCount > 4000 || !AppleLLM.isAvailable { return reply("error") }
        let sys = buildSystem(body)
        let prompt = "TEXT TO POLISH:\n<<<\n\(text)\n>>>"
        let est = Int(Double(wordCount) * 1.6) + 60
        let maxTokens = min(3 * est + 256, 3500)
        do {
            let raw = try await race(timeout: 20) {
                try await AppleLLM.respond(instructions: sys, prompt: prompt, maxTokens: maxTokens)
            }
            var out = PostProcess.stripEchoes(raw).trimmingCharacters(in: .whitespacesAndNewlines)
            if out.hasPrefix("```") {
                var lines = out.components(separatedBy: "\n")
                lines.removeFirst()
                if lines.last?.hasPrefix("```") == true { lines.removeLast() }
                out = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if out.isEmpty { return reply("no_text") }
            if squash(out) == squash(text) { return reply("no_changes") }
            return reply("ok", out)
        } catch is RaceTimeout {
            return reply("timeout")
        } catch {
            elog("polish error: \(error)")
            return reply("error")
        }
    }
}
