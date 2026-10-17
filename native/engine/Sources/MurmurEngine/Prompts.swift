import Foundation

/// Loads the shared prompts bundled as SwiftPM resources (copied from shared/prompts at build time).
struct Prompts {
    let formatSystem: String
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
}
