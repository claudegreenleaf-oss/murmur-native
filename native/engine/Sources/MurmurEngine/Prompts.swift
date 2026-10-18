import Foundation

/// Loads the shared prompts bundled as SwiftPM resources (copied from shared/prompts at build time).
struct Prompts {
    let formatSystem: String
    let formatSystemStudent: String
    let commandSystem: String
    let extractSystem: String
    let strength: [String: String]
    let style: [String: String]
    let appType: [String: String]
    let styleCategory: [String: String]

    static let shared: Prompts = Prompts.load()

    static func text(_ name: String, _ ext: String) -> String {
        let urls = [
            Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "prompts"),
            Bundle.module.url(forResource: name, withExtension: ext),
        ]
        for u in urls {
            if let u = u, let s = try? String(contentsOf: u, encoding: .utf8) { return s }
        }
        elog("missing bundled prompt \(name).\(ext)")
        return ""
    }

    private static func load() -> Prompts {
        let frag = parseJSON(Data(text("format-fragments", "json").utf8)) ?? [:]
        func map(_ k: String) -> [String: String] { frag.strMap(k) }
        return Prompts(
            formatSystem: text("format-system", "txt"),
            formatSystemStudent: text("format-system-student", "txt"),
            commandSystem: text("command-system", "txt"),
            extractSystem: text("extract-edited-words-system", "txt"),
            strength: map("editing_strength"),
            style: map("writing_style"),
            appType: map("app_type"),
            styleCategory: map("style_category_for_app_type"))
    }

    /// System message exactly as format-request.md describes. `budget` trims the cursor context so
    /// the request fits Apple's ~4k token window.
    func systemMessage(ini: InitInfo, ctx: ContextInfo, instruction: String?, compact: Bool) -> String {
        var parts: [String] = [formatSystem]
        var frag: [String] = []
        if let s = strength[ini.editingStrength] { frag.append(s) }
        let category = styleCategory[ctx.appType] ?? "other"
        let styleName = ini.generalStyle[category] ?? "formal"
        if let s = style[styleName] { frag.append(s) }
        if let a = appType[ctx.appType], !a.isEmpty { frag.append(a) }
        if let instruction = instruction, !instruction.isEmpty { frag.append("Additional instruction: " + instruction) }
        parts.append(frag.joined(separator: "\n"))

        let cap = compact ? 300 : 500
        var c: [String] = []
        let name = (ini.firstName + " " + ini.lastName).trimmingCharacters(in: .whitespaces)
        if !name.isEmpty { c.append("USER NAME: " + name) }
        let vocab = ini.vocabulary
        if !vocab.isEmpty { c.append("VOCABULARY: " + vocab.joined(separator: ", ")) }
        if !ctx.appName.isEmpty || !ctx.bundleId.isEmpty {
            var line = "APP: \(ctx.appName) (\(ctx.bundleId))"
            if !ctx.url.isEmpty { line += ", " + ctx.url }
            c.append(line)
        }
        if !ctx.windowTitle.isEmpty { c.append("WINDOW: " + ctx.windowTitle) }
        if !ctx.before.isEmpty { c.append("TEXT BEFORE CURSOR:\n<<<\n\(String(ctx.before.suffix(cap)))\n>>>") }
        if !ctx.selected.isEmpty { c.append("SELECTED TEXT:\n<<<\n\(String(ctx.selected.prefix(cap)))\n>>>") }
        if !ctx.after.isEmpty { c.append("TEXT AFTER CURSOR:\n<<<\n\(String(ctx.after.prefix(cap)))\n>>>") }
        let screen = Array(ctx.screenWords.prefix(compact ? 60 : 150))
        if !screen.isEmpty { c.append("SCREEN WORDS: " + screen.joined(separator: ", ")) }
        if !c.isEmpty { parts.append(c.joined(separator: "\n")) }
        return parts.joined(separator: "\n\n")
    }

    static func userMessage(_ transcript: String) -> String {
        "TRANSCRIPT:\n<<<\n\(transcript)\n>>>"
    }

    // MARK: Student (distilled formatter) prompt

    /// System message for the local MLX formatter. Mirrors the a6000 server's `prompts.system_message` and
    /// `formatting.context_block` byte for byte, with the static rules replaced by format-system-student.txt.
    func studentSystemMessage(ini: InitInfo, ctx: ContextInfo) -> String {
        var rules = formatSystemStudent
        while rules.hasSuffix("\n") { rules.removeLast() }
        // The server joins [rules, "", fragment...] with "\n", so the first fragment follows a blank line.
        var parts: [String] = [rules, ""]
        let category = styleCategory[ctx.appType] ?? "other"
        let writing = ini.generalStyle[category] ?? "formal"
        for f in [strength[ini.editingStrength] ?? "", style[writing] ?? "", appType[ctx.appType] ?? ""] where !f.isEmpty {
            parts.append(f)
        }
        var msg = parts.joined(separator: "\n")
        let block = Self.studentContextBlock(ini: ini, ctx: ctx)
        if !block.isEmpty { msg += "\n\n" + block }
        return msg
    }

    /// Order-preserving, case-insensitive de-duplication of stripped items (the server's `_dedupe`).
    private static func dedupe(_ items: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for raw in items {
            let it = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let k = it.lowercased()
            if it.isEmpty || seen.contains(k) { continue }
            seen.insert(k)
            out.append(it)
        }
        return out
    }

    private static func studentContextBlock(ini: InitInfo, ctx: ContextInfo) -> String {
        var lines: [String] = []
        let name = [ini.firstName, ini.lastName].filter { !$0.isEmpty }.joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { lines.append("USER NAME: " + name) }
        let vocab = Array(dedupe(ini.starred + ini.dictionary).prefix(200))
        if !vocab.isEmpty { lines.append("VOCABULARY: " + vocab.joined(separator: ", ")) }
        if !ctx.appName.isEmpty || !ctx.bundleId.isEmpty {
            var line = "APP: \(ctx.appName) (\(ctx.bundleId))"
            if !ctx.url.isEmpty { line += ", " + ctx.url }
            lines.append(line)
        }
        if !ctx.windowTitle.isEmpty { lines.append("WINDOW: " + ctx.windowTitle) }
        // Python slices by code point, so slice by unicode scalar rather than by Character.
        if !ctx.before.isEmpty {
            lines.append("TEXT BEFORE CURSOR:\n<<<\n" + String(String.UnicodeScalarView(ctx.before.unicodeScalars.suffix(500))) + "\n>>>")
        }
        if !ctx.selected.isEmpty { lines.append("SELECTED TEXT:\n<<<\n" + ctx.selected + "\n>>>") }
        if !ctx.after.isEmpty {
            lines.append("TEXT AFTER CURSOR:\n<<<\n" + String(String.UnicodeScalarView(ctx.after.unicodeScalars.prefix(500))) + "\n>>>")
        }
        let screen = Array(dedupe(ctx.screenAx + ctx.variableNames + ctx.fileNames + ctx.screenOcr).prefix(150))
        if !screen.isEmpty { lines.append("SCREEN WORDS: " + screen.joined(separator: ", ")) }
        return lines.joined(separator: "\n")
    }

    /// The server's `user_message(raw)`.
    static func studentUserMessage(_ transcript: String) -> String {
        "TRANSCRIPT:\n<<<\n\(transcript)\n>>>\n\nOutput the cleaned transcript text only."
    }
}
