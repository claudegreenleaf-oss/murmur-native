import Foundation

struct InitInfo {
    var sessionId = ""
    var requestId = ""
    var mode = "dictation"
    var firstName = ""
    var lastName = ""
    var languages: [String] = []
    var dictionary: [String] = []
    var starred: [String] = []
    var replacements: [String: String] = [:]
    var snippets: [String: String] = [:]
    var generalStyle: [String: String] = [:]
    var editingStrength = "verbatim"
    var format = "ai"

    init() {}

    init(json: JSON?) {
        guard let j = json else { return }
        if let m = j.obj("metadata") {
            sessionId = m.str("session_id")
            requestId = m.str("request_id")
            let md = m.str("mode")
            if !md.isEmpty { mode = md }
        }
        if let p = j.obj("preferences") {
            if let u = p.obj("user") {
                firstName = u.str("first_name")
                lastName = u.str("last_name")
            }
            languages = p.strs("languages")
            if let v = p.obj("vocabulary") {
                dictionary = v.strs("dictionary")
                starred = v.strs("starred")
            }
            replacements = p.strMap("replacements")
            snippets = p.strMap("snippets")
            if let s = p.obj("style") {
                generalStyle = s.obj("general_style")?.reduce(into: [String: String]()) { acc, kv in
                    if let v = kv.value as? String { acc[kv.key] = v }
                } ?? [:]
                let es = s.str("editing_strength")
                if !es.isEmpty { editingStrength = es }
                let f = s.str("format")
                if !f.isEmpty { format = f }
            }
        }
    }

    /// Starred first, then the rest, de-duplicated, capped at 200.
    var vocabulary: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for t in starred + dictionary {
            let k = t.lowercased()
            if t.isEmpty || seen.contains(k) { continue }
            seen.insert(k)
            out.append(t)
            if out.count >= 200 { break }
        }
        return out
    }

    var userNameWords: [String] {
        (firstName + " " + lastName).split(separator: " ").map(String.init)
    }

    var primaryLanguage: String? {
        guard let l = languages.first?.lowercased(), !l.isEmpty, l != "auto" else { return nil }
        return l
    }
}

struct ContextInfo {
    var appName = ""
    var bundleId = ""
    var url = ""
    var windowTitle = ""
    var appType = "other"
    var before = ""
    var selected = ""
    var after = ""
    var screenAx: [String] = []
    var screenOcr: [String] = []
    var variableNames: [String] = []
    var fileNames: [String] = []

    init() {}

    init(json: JSON?) {
        guard let j = json else { return }
        if let a = j.obj("app") {
            appName = a.str("name")
            bundleId = a.str("bundle_id")
            url = a.str("url")
            windowTitle = a.str("window_title")
            let t = a.str("type")
            if !t.isEmpty { appType = t }
        }
        if let t = j.obj("textbox") {
            before = t.str("before_text")
            selected = t.str("selected_text")
            after = t.str("after_text")
        }
        if let v = j.obj("vocabulary") {
            screenAx = v.strs("screen_ax")
            screenOcr = v.strs("screen_ocr")
            variableNames = v.strs("variable_names")
            fileNames = v.strs("file_names")
        }
    }

    /// screen_ax + variable_names + file_names + screen_ocr, de-duplicated, max 150.
    var screenWords: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for t in screenAx + variableNames + fileNames + screenOcr {
            let k = t.lowercased()
            if t.isEmpty || seen.contains(k) { continue }
            seen.insert(k)
            out.append(t)
            if out.count >= 150 { break }
        }
        return out
    }
}

enum Level {
    static func dbFromRms(_ rms: Float) -> Float {
        20 * log10(max(rms, 1e-6))
    }
}
