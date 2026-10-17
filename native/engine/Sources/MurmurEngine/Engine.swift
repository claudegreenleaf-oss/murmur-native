import Foundation

let engine = Engine()

/// Shared services plus the plain-HTTP endpoint handlers.
final class Engine: @unchecked Sendable {
    let asr = ASREngine()
    let formatter = TextFormatter()

    func health() async -> JSON {
        [
            "ok": true,
            "engine": "local",
            "asr": ASREngine.modelName,
            "llm": (AppleLLM.isAvailable ? ("apple-foundation-models" as Any) : (NSNull() as Any)),
            "version": "1",
        ]
    }

    func warmUp() {
        Task { await self.asr.warm() }
        Task { await AppleLLM.warmUp() }
    }

    func handleFormat(_ body: JSON) async -> JSON {
        let ini = InitInfo(json: body.obj("init"))
        let ctx = ContextInfo(json: body.obj("context"))
        let text = body.str("text")
        let instruction = body.str("instruction")
        let o = await formatter.run(raw: text, ini: ini, ctx: ctx, instruction: instruction.isEmpty ? nil : instruction)
        return [
            "plaintext": o.plaintext,
            "html": o.html,
            "status": o.status,
            "format_skip_reason": o.skipReason,
        ]
    }

    func handleCommand(_ body: JSON) async -> JSON {
        let ctx = ContextInfo(json: body.obj("context"))
        do {
            let text = try await formatter.runCommand(
                instruction: body.str("instruction_text"), selected: body.str("selected_text"), ctx: ctx)
            return ["plaintext": text, "html": PostProcess.toHTML(text), "status": "formatted"]
        } catch {
            return ["plaintext": "", "html": "", "status": "error"]
        }
    }

    func handleExtract(_ body: JSON) async -> JSON {
        let potential = body.strs("potential_words")
        var cands: [(word: String, source: String)] = []
        for item in (body["candidates"] as? [Any]) ?? [] {
            guard let d = item as? JSON else { continue }
            cands.append((word: d.str("word"), source: d.str("observed_source")))
        }
        let accepted = await formatter.extractEditedWords(
            potential: potential, candidates: cands, source: body.str("source"))
        return ["accepted_candidates": accepted.map { ["word": $0.0, "observed_source": $0.1] }]
    }
}
