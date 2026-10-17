import ApplicationServices
import AppKit
import Foundation

// MARK: attribute names

let axaFocusedUIElement = "AXFocusedUIElement"
let axaFocusedWindow = "AXFocusedWindow"
let axaMainWindow = "AXMainWindow"
let axaRole = "AXRole"
let axaSubrole = "AXSubrole"
let axaValue = "AXValue"
let axaTitle = "AXTitle"
let axaDesc = "AXDescription"
let axaPlaceholder = "AXPlaceholderValue"
let axaChildren = "AXChildren"
let axaParent = "AXParent"
let axaURL = "AXURL"
let axaSelRange = "AXSelectedTextRange"
let axaSelText = "AXSelectedText"

// MARK: low-level helpers

func axCopy(_ el: AXUIElement, _ attr: String) -> CFTypeRef? {
    var v: CFTypeRef?
    return AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success ? v : nil
}

func axStr(_ el: AXUIElement, _ attr: String) -> String? {
    axCopy(el, attr) as? String
}

func axElem(_ el: AXUIElement, _ attr: String) -> AXUIElement? {
    guard let v = axCopy(el, attr), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
    return unsafeBitCast(v, to: AXUIElement.self)
}

func axRange(_ el: AXUIElement, _ attr: String) -> CFRange? {
    guard let v = axCopy(el, attr), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
    let av = unsafeBitCast(v, to: AXValue.self)
    guard AXValueGetType(av) == .cfRange else { return nil }
    var r = CFRange(location: 0, length: 0)
    return AXValueGetValue(av, .cfRange, &r) ? r : nil
}

func axSettable(_ el: AXUIElement, _ attr: String) -> Bool {
    var s = DarwinBoolean(false)
    return AXUIElementIsAttributeSettable(el, attr as CFString, &s) == .success && s.boolValue
}

func axChildren(_ el: AXUIElement) -> [AXUIElement] {
    (axCopy(el, axaChildren) as? [AXUIElement]) ?? []
}

func axPid(_ el: AXUIElement) -> pid_t {
    var pid: pid_t = 0
    AXUIElementGetPid(el, &pid)
    return pid
}

/// Reads several attributes in one round trip; missing attributes come back as nil.
func axMulti(_ el: AXUIElement, _ attrs: [String]) -> [CFTypeRef?] {
    var out: CFArray?
    let err = AXUIElementCopyMultipleAttributeValues(el, attrs as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &out)
    guard err == .success, let arr = out as? [AnyObject] else {
        return [CFTypeRef?](repeating: nil, count: attrs.count)
    }
    return arr.map { item -> CFTypeRef? in
        let cf = item as CFTypeRef
        if CFGetTypeID(cf) == AXValueGetTypeID(), AXValueGetType(unsafeBitCast(cf, to: AXValue.self)) == .axError {
            return nil
        }
        if item is NSNull { return nil }
        return cf
    }
}

func axAppElement(_ pid: pid_t) -> AXUIElement {
    let e = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(e, 0.25)
    return e
}

// MARK: app classification

enum AppKinds {
    static let browsers: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary",
        "com.brave.Browser", "com.brave.Browser.beta", "com.brave.Browser.nightly", "com.microsoft.edgemac",
        "com.apple.Safari", "com.apple.SafariTechnologyPreview", "company.thebrowser.Browser", "company.thebrowser.dia",
        "com.vivaldi.Vivaldi", "com.operasoftware.Opera", "app.zen-browser.zen", "com.openai.atlas",
        "org.chromium.Chromium", "net.imput.helium", "com.mullvad.mullvadbrowser", "org.mozilla.firefox",
    ]
    static let terminals: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "dev.warp.Warp",
        "com.mitchellh.ghostty", "net.kovidgoyal.kitty", "io.alacritty", "co.zeit.hyper", "com.github.wez.wezterm",
    ]
    static let ides: Set<String> = [
        "com.todesktop.230313mzl4w4u92", "com.exafunction.windsurf", "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders", "com.apple.dt.Xcode", "dev.zed.Zed",
    ]

    private static let chromiumCache = Locked<[pid_t: Bool]>([:])
    private static let enabledPids = Locked<Set<pid_t>>([])

    static func isChromiumLike(_ app: NSRunningApplication) -> Bool {
        if let c = chromiumCache.get()[app.processIdentifier] { return c }
        var result = false
        if let b = app.bundleIdentifier, browsers.contains(b), b != "com.apple.Safari", b != "org.mozilla.firefox" {
            result = true
        } else if let url = app.bundleURL {
            let fw = url.appendingPathComponent("Contents/Frameworks").path
            let names = (try? FileManager.default.contentsOfDirectory(atPath: fw)) ?? []
            let vendors = ["Chrome", "Chromium", "Brave", "Edge", "Vivaldi", "Opera"]
            result = names.contains { name in
                if name.hasPrefix("Electron Framework") || name.hasPrefix("Chromium Embedded") { return true }
                return name.hasSuffix("Framework.framework") && vendors.contains { name.contains($0) }
            }
        }
        chromiumCache.mutate { $0[app.processIdentifier] = result }
        return result
    }

    static func isBrowserLike(_ app: NSRunningApplication) -> Bool {
        if let b = app.bundleIdentifier, browsers.contains(b) { return true }
        return isChromiumLike(app)
    }

    /// Chromium/Electron only build their accessibility tree when asked.
    static func ensureAccessibility(_ app: NSRunningApplication) {
        guard isChromiumLike(app) else { return }
        let pid = app.processIdentifier
        let first = enabledPids.mutate { $0.insert(pid).inserted }
        guard first else { return }
        let el = axAppElement(pid)
        AXUIElementSetAttributeValue(el, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(el, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        sleepMs(120)
    }
}

// MARK: focus

struct FocusRef {
    let element: AXUIElement
    let pid: pid_t
}

func currentFocus() -> FocusRef? {
    if let app = NSWorkspace.shared.frontmostApplication {
        AppKinds.ensureAccessibility(app)
    }
    let sys = AXUIElementCreateSystemWide()
    AXUIElementSetMessagingTimeout(sys, 0.25)
    if let el = axElem(sys, axaFocusedUIElement) {
        return FocusRef(element: el, pid: axPid(el))
    }
    // getFocusedUIElementFromSystem returned nil, trying frontmost app window as fallback
    guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
    let ael = axAppElement(app.processIdentifier)
    if let el = axElem(ael, axaFocusedUIElement) ?? axElem(ael, axaFocusedWindow) {
        return FocusRef(element: el, pid: app.processIdentifier)
    }
    return nil
}

// MARK: text box

struct TextBox {
    var functioning = false
    var contents = ""
    var before = ""
    var selected = ""
    var after = ""
    var editable = false
    var couldNot = true
    var hash: Int?

    func json() -> JSON {
        let maxSide = 8000
        var b = before
        var a = after
        var c = contents
        if contents.count > 2 * maxSide + selected.count {
            b = String(before.suffix(maxSide))
            a = String(after.prefix(maxSide))
            c = b + selected + a
        }
        var d: JSON = [
            "accessibilityIsFunctioning": functioning,
            "contents": c,
            "beforeText": b,
            "selectedText": truncatedJSONString(selected, 8000),
            "afterText": a,
            "isEditable": editable,
            "couldNotGetTextBoxInfo": couldNot,
        ]
        if let h = hash { d["focusedElementHash"] = h }
        return d
    }
}

func readTextBox(_ focus: FocusRef?) -> TextBox {
    var tb = TextBox()
    tb.functioning = AXIsProcessTrusted()
    guard tb.functioning, let focus else { return tb }
    let el = focus.element
    AXUIElementSetMessagingTimeout(el, 0.25)
    tb.hash = Int(truncatingIfNeeded: CFHash(el))
    let role = axStr(el, axaRole) ?? ""
    let subrole = axStr(el, axaSubrole) ?? ""
    if subrole == "AXSecureTextField" { return tb }

    tb.editable = axSettable(el, axaValue) || axSettable(el, axaSelRange)
        || ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"].contains(role)

    guard var value = axStr(el, axaValue) else {
        // No string value: fall back to the selection only.
        if let sel = axStr(el, axaSelText), !sel.isEmpty {
            tb.selected = sel
            tb.contents = sel
            tb.couldNot = false
        }
        return tb
    }
    if let ph = axStr(el, axaPlaceholder), ph == value { value = "" }
    tb.contents = value
    tb.couldNot = false

    let ns = value as NSString
    if let r = axRange(el, axaSelRange), r.location >= 0, r.location <= ns.length {
        let loc = r.location
        let len = max(0, min(r.length, ns.length - loc))
        tb.before = ns.substring(to: loc)
        tb.selected = ns.substring(with: NSRange(location: loc, length: len))
        tb.after = ns.substring(from: loc + len)
    } else if let sel = axStr(el, axaSelText), !sel.isEmpty {
        let parts = value.components(separatedBy: sel)
        if parts.count == 2 {
            tb.before = parts[0]
            tb.selected = sel
            tb.after = parts[1]
        } else {
            // Failed to find unique range for selected text in contents
            tb.before = value
            tb.selected = sel
        }
    } else {
        tb.before = value
    }
    return tb
}

// MARK: app info

struct AppInfo {
    var appName = ""
    var bundleId = ""
    var url = ""
    var windowTitle = ""
    var cli: (agent: String, confidence: String)?

    func json() -> JSON {
        var d: JSON = ["appName": appName, "bundleId": bundleId, "url": url, "windowTitle": windowTitle]
        if let c = cli {
            d["codingCliAgent"] = c.agent
            d["codingCliAgentConfidence"] = c.confidence
        }
        return d
    }
}

private func urlString(_ el: AXUIElement) -> String? {
    guard let v = axCopy(el, axaURL) else { return nil }
    if CFGetTypeID(v) == CFURLGetTypeID() {
        return (unsafeBitCast(v, to: CFURL.self) as URL).absoluteString
    }
    return v as? String
}

private func findWebAreaURL(focused: AXUIElement?, window: AXUIElement?, deadline: Double) -> String {
    var cur = focused
    var depth = 0
    while let c = cur, depth < 60, monoMs() < deadline {
        if axStr(c, axaRole) == "AXWebArea", let u = urlString(c) { return u }
        cur = axElem(c, axaParent)
        depth += 1
    }
    guard let window else { return "" }
    // AXWebArea URL search
    var queue: [(AXUIElement, Int)] = [(window, 0)]
    var i = 0
    while i < queue.count, i < 700, monoMs() < deadline {
        let (el, d) = queue[i]
        i += 1
        let vals = axMulti(el, [axaRole, axaChildren])
        if (vals[0] as? String) == "AXWebArea", let u = urlString(el) { return u }
        if d < 12, let kids = vals[1] as? [AXUIElement] {
            for k in kids { queue.append((k, d + 1)) }
        }
    }
    return ""
}

func readAppInfo(focus: FocusRef?) -> AppInfo {
    var info = AppInfo()
    guard let app = NSWorkspace.shared.frontmostApplication else { return info }
    info.appName = app.localizedName ?? ""
    info.bundleId = app.bundleIdentifier ?? ""
    guard AXIsProcessTrusted() else { return info }
    let ael = axAppElement(app.processIdentifier)
    let window = axElem(ael, axaFocusedWindow) ?? axElem(ael, axaMainWindow)
    if let w = window {
        info.windowTitle = axStr(w, axaTitle) ?? ""
    }
    if AppKinds.isBrowserLike(app) {
        info.url = findWebAreaURL(focused: focus?.element, window: window, deadline: monoMs() + 250)
    }
    if AppKinds.terminals.contains(info.bundleId) {
        var text = ""
        if let f = focus, let v = axStr(f.element, axaValue) { text = v }
        if text.isEmpty, let w = window {
            text = terminalText(window: w)
        }
        info.cli = detectCodingCli(text: text, title: info.windowTitle)
    }
    return info
}

private func terminalText(window: AXUIElement) -> String {
    var queue: [(AXUIElement, Int)] = [(window, 0)]
    var i = 0
    let deadline = monoMs() + 150
    while i < queue.count, i < 150, monoMs() < deadline {
        let (el, d) = queue[i]
        i += 1
        let vals = axMulti(el, [axaRole, axaValue, axaChildren])
        if (vals[0] as? String) == "AXTextArea", let v = vals[1] as? String, !v.isEmpty { return v }
        if d < 8, let kids = vals[2] as? [AXUIElement] {
            for k in kids { queue.append((k, d + 1)) }
        }
    }
    return ""
}

func detectCodingCli(text: String, title: String) -> (agent: String, confidence: String)? {
    let t = String(text.suffix(8000)).lowercased()
    let ti = title.lowercased()
    let high: [(String, [String])] = [
        ("claude", ["claude code", "welcome to claude"]),
        ("codex", ["openai codex", ">_ openai codex"]),
        ("gemini", ["gemini cli", "gemini-cli"]),
        ("aider", ["aider v", "aider --"]),
        ("opencode", ["opencode v", "opencode -"]),
        ("qwen", ["qwen code"]),
        ("cursor-agent", ["cursor agent", "cursor-agent"]),
        ("cline", ["cline cli"]),
    ]
    for (agent, phrases) in high where phrases.contains(where: { t.contains($0) || ti.contains($0) }) {
        return (agent, "high")
    }
    let low = ["claude", "codex", "gemini", "aider", "opencode", "qwen", "cursor-agent", "cline"]
    for agent in low where ti.contains(agent) { return (agent, "low") }
    for agent in low where t.contains(agent) && (agent == "claude" || agent == "codex" || agent == "gemini") {
        return (agent, "low")
    }
    return nil
}

// MARK: app context

struct AppContext {
    var nearestTexts = ""
    var axWords: [String] = []
    var fileNames: [String] = []
    var variableNames: [String] = []

    func json() -> JSON {
        [
            "nearestTexts": truncatedJSONString(nearestTexts, 6000),
            "axWords": axWords,
            "fileNames": fileNames,
            "variableNames": variableNames,
        ]
    }
}

private let stopWords: Set<String> = [
    "the", "this", "that", "and", "for", "with", "from", "you", "your", "are", "was", "were", "has", "have", "had",
    "not", "but", "all", "any", "can", "will", "new", "open", "save", "edit", "file", "view", "window", "help",
    "settings", "search", "home", "back", "next", "send", "share", "close", "more", "less", "show", "hide", "none",
    "yes", "cancel", "done", "delete", "copy", "paste", "undo", "redo", "select", "today", "untitled",
]

private let fileRegex = try? NSRegularExpression(
    pattern: #"[A-Za-z0-9_\-\.]+\.(?:swift|ts|tsx|js|jsx|py|rs|go|java|kt|cpp|c|h|hpp|m|mm|md|json|yaml|yml|toml|html|css|sh|rb|php|sql|txt|csv|pdf|docx|xlsx|ipynb)\b"#
)

private func nodeTexts(_ vals: [CFTypeRef?]) -> [String] {
    // vals: role, subrole, value, title, description
    if (vals[1] as? String) == "AXSecureTextField" { return [] }
    var out: [String] = []
    for i in 2...4 {
        if let s = vals[i] as? String, !s.isEmpty { out.append(String(s.prefix(2000))) }
    }
    return out
}

private func tokenize(_ s: String) -> [String] {
    var tokens: [String] = []
    var cur = ""
    for u in s.unicodeScalars {
        if CharacterSet.alphanumerics.contains(u) || u == "_" || u == "'" || u == "-" {
            cur.unicodeScalars.append(u)
        } else if !cur.isEmpty {
            tokens.append(cur)
            cur = ""
        }
    }
    if !cur.isEmpty { tokens.append(cur) }
    return tokens.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'-")) }.filter { !$0.isEmpty }
}

func extractWords(from texts: [String], limit: Int) -> [String] {
    var lowerSeen = Set<String>()
    var all: [String] = []
    for t in texts { all.append(contentsOf: tokenize(t)) }
    for tok in all {
        if let f = tok.unicodeScalars.first, CharacterSet.lowercaseLetters.contains(f) { lowerSeen.insert(tok.lowercased()) }
    }
    var seen = Set<String>()
    var out: [String] = []
    for tok in all {
        guard tok.count >= 3, tok.count <= 30 else { continue }
        let lower = tok.lowercased()
        if seen.contains(lower) || stopWords.contains(lower) { continue }
        let scalars = Array(tok.unicodeScalars)
        let upper = CharacterSet.uppercaseLetters
        let lowerSet = CharacterSet.lowercaseLetters
        let firstUpper = upper.contains(scalars[0])
        let innerUpper = scalars.dropFirst().contains { upper.contains($0) }
        let hasLower = scalars.contains { lowerSet.contains($0) }
        let hasDigit = scalars.contains { CharacterSet.decimalDigits.contains($0) }
        let allCaps = !hasLower && scalars.contains { upper.contains($0) }
        var keep = false
        if firstUpper && hasLower && !lowerSeen.contains(lower) { keep = true }
        if innerUpper && hasLower { keep = true }
        if allCaps && tok.count <= 8 { keep = true }
        if hasDigit && scalars.contains(where: { upper.contains($0) }) { keep = true }
        if keep {
            seen.insert(lower)
            out.append(tok)
            if out.count >= limit { break }
        }
    }
    return out
}

func readAppContext(focus: FocusRef?, bundleId: String, windowTitle: String, useAx: Bool) -> AppContext {
    var ctx = AppContext()
    guard AXIsProcessTrusted(), useAx, let app = NSWorkspace.shared.frontmostApplication else { return ctx }
    let start = monoMs()
    let deadline = start + 150
    let attrs = [axaRole, axaSubrole, axaValue, axaTitle, axaDesc, axaChildren]

    // Nearest texts: siblings of the focused element, walking up a few levels.
    if let f = focus {
        var chunks: [String] = []
        var total = 0
        var level = axElem(f.element, axaParent)
        var depth = 0
        while let parent = level, depth < 4, total < 3000, monoMs() < deadline - 50 {
            for kid in axChildren(parent).prefix(40) {
                if CFEqual(kid, f.element) { continue }
                let vals = axMulti(kid, attrs)
                for t in nodeTexts(vals) where total < 3000 {
                    chunks.append(t)
                    total += t.count
                }
            }
            level = axElem(parent, axaParent)
            depth += 1
        }
        ctx.nearestTexts = chunks.joined(separator: "\n")
    }

    // Window walk for proper-noun-like words.
    var texts: [String] = []
    if !windowTitle.isEmpty { texts.append(windowTitle) }
    let ael = axAppElement(app.processIdentifier)
    if let window = axElem(ael, axaFocusedWindow) ?? axElem(ael, axaMainWindow) {
        var queue: [(AXUIElement, Int)] = [(window, 0)]
        var i = 0
        while i < queue.count, i < 400, monoMs() < deadline {
            let (el, d) = queue[i]
            i += 1
            let vals = axMulti(el, attrs)
            texts.append(contentsOf: nodeTexts(vals))
            if d < 10, let kids = vals[5] as? [AXUIElement] {
                for k in kids { queue.append((k, d + 1)) }
            }
        }
    }
    ctx.axWords = extractWords(from: texts + [ctx.nearestTexts], limit: 150)

    // File names and identifiers (editors, terminals).
    let blob = (texts + [ctx.nearestTexts]).joined(separator: "\n")
    if let re = fileRegex {
        let ns = blob as NSString
        var seen = Set<String>()
        for m in re.matches(in: blob, range: NSRange(location: 0, length: min(ns.length, 60000))) {
            let name = ns.substring(with: m.range)
            if seen.insert(name).inserted { ctx.fileNames.append(name) }
            if ctx.fileNames.count >= 40 { break }
        }
    }
    if AppKinds.ides.contains(bundleId) || AppKinds.terminals.contains(bundleId) {
        var seen = Set<String>()
        for tok in tokenize(blob) where tok.count >= 4 && tok.count <= 40 {
            let hasUnderscore = tok.contains("_") && tok.rangeOfCharacter(from: .letters) != nil
            let chars = Array(tok)
            var camel = false
            if let f = chars.first, f.isLowercase {
                for k in 1..<chars.count where chars[k].isUppercase && chars[k - 1].isLowercase { camel = true }
            }
            if (hasUnderscore || camel) && seen.insert(tok).inserted {
                ctx.variableNames.append(tok)
                if ctx.variableNames.count >= 40 { break }
            }
        }
    }
    return ctx
}

/// Front tab URL and window title of a specific (browser) process.
func readBrowserTabInfo(pid: pid_t) -> JSON {
    guard AXIsProcessTrusted(), let app = NSRunningApplication(processIdentifier: pid) else {
        return ["url": "", "title": "", "bundleId": ""]
    }
    AppKinds.ensureAccessibility(app)
    let ael = axAppElement(pid)
    let window = axElem(ael, axaFocusedWindow) ?? axElem(ael, axaMainWindow)
    let title = window.flatMap { axStr($0, axaTitle) } ?? ""
    let focused = axElem(ael, axaFocusedUIElement)
    let url = findWebAreaURL(focused: focused, window: window, deadline: monoMs() + 300)
    return ["url": url, "title": title, "bundleId": app.bundleIdentifier ?? ""]
}
