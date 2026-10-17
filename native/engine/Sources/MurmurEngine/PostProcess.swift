import Foundation

/// Engine post-processing steps from shared/prompts/format-request.md.
enum PostProcess {
    static func words(_ s: String) -> [String] {
        s.lowercased().split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "'") }).map(String.init)
    }

    static func normalizedKey(_ s: String) -> String {
        words(s).joined(separator: " ")
    }

    // MARK: 1. Strip echoes and wrapping quotes

    static func stripEchoes(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        t = t.replacingOccurrences(of: "<<<\n", with: "").replacingOccurrences(of: "\n>>>", with: "")
        t = t.replacingOccurrences(of: "<<<", with: "").replacingOccurrences(of: ">>>", with: "")
        if t.uppercased().hasPrefix("TRANSCRIPT:") {
            t = String(t.dropFirst("TRANSCRIPT:".count))
        }
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        let pairs: [(Character, Character)] = [("\"", "\""), ("\u{201C}", "\u{201D}"), ("'", "'")]
        for (a, b) in pairs where t.count >= 2 && t.first == a && t.last == b {
            let inner = t.dropFirst().dropLast()
            if !inner.contains(a) { t = String(inner).trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        return t
    }

    // MARK: 2. Hallucination guard

    static func looksHallucinated(output: String, transcript: String, strength: String) -> Bool {
        let outWords = words(output)
        let inWords = words(transcript)
        if inWords.isEmpty { return !outWords.isEmpty }
        if Double(outWords.count) > Double(inWords.count) * 1.6 + 20 { return true }
        let lower = output.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        for p in ["sure", "here is", "here's", "certainly", "as an ai", "i can't", "i cannot", "i'm sorry", "i am sorry", "of course"] {
            if lower.hasPrefix(p) && !transcript.lowercased().hasPrefix(p) { return true }
        }
        let threshold = (strength == "verbatim" || strength == "light") ? 0.5 : 0.3
        if outWords.isEmpty { return false }
        let inSet = Set(inWords)
        let hits = outWords.filter { inSet.contains($0) }.count
        return Double(hits) / Double(outWords.count) < threshold
    }

    // MARK: 3. Snippets

    /// Returns the expansion when the whole utterance is a trigger.
    static func wholeUtteranceSnippet(_ text: String, _ snippets: [String: String]) -> String? {
        let key = normalizedKey(text)
        if key.isEmpty { return nil }
        for (trigger, expansion) in snippets where normalizedKey(trigger) == key { return expansion }
        return nil
    }

    static func applySnippets(_ text: String, _ snippets: [String: String]) -> String {
        var out = text
        // Longest triggers first so "my email address" wins over "my email".
        for (trigger, expansion) in snippets.sorted(by: { $0.key.count > $1.key.count }) {
            let t = trigger.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { continue }
            let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: t) + "(?![\\p{L}\\p{N}])[,.!?;:]?"
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            out = re.stringByReplacingMatches(
                in: out, range: NSRange(out.startIndex..., in: out),
                withTemplate: NSRegularExpression.escapedTemplate(for: expansion))
        }
        return out
    }

    // MARK: 4. Format modes

    static func lowercaseSentenceStarts(_ text: String, properNouns: Set<String>) -> String {
        var out = ""
        var atStart = true
        var i = text.startIndex
        while i < text.endIndex {
            let ch = text[i]
            if atStart {
                // Skip list markers and whitespace.
                if ch == " " || ch == "\n" || ch == "-" || ch.isNumber || ch == "." && out.last?.isNumber == true {
                    out.append(ch); i = text.index(after: i); continue
                }
                if ch.isLetter {
                    var j = i
                    while j < text.endIndex, text[j].isLetter || text[j] == "'" || text[j].isNumber { j = text.index(after: j) }
                    let word = String(text[i..<j])
                    let lw = word.lowercased()
                    let keep = word == "I" || lw.hasPrefix("i'") && word.hasPrefix("I") || properNouns.contains(lw)
                    out += keep ? word : lw
                    i = j
                    atStart = false
                    continue
                }
                atStart = false
            }
            out.append(ch)
            if ch == "." || ch == "!" || ch == "?" || ch == "\n" { atStart = true }
            i = text.index(after: i)
        }
        return out
    }

    /// Words treated as proper nouns: vocabulary, user name, screen words, mid-sentence capitals of the transcript.
    static func properNounSet(ini: InitInfo, ctx: ContextInfo, transcript: String) -> Set<String> {
        var set = Set<String>()
        for t in ini.vocabulary + ini.userNameWords + ctx.screenWords {
            for w in t.split(separator: " ") { set.insert(w.lowercased()) }
        }
        var atStart = true
        for token in transcript.split(separator: " ") {
            let bare = token.trimmingCharacters(in: .punctuationCharacters)
            if !atStart, let f = bare.first, f.isUppercase, bare != "I", !bare.hasPrefix("I'") {
                set.insert(bare.lowercased())
            }
            atStart = token.hasSuffix(".") || token.hasSuffix("!") || token.hasSuffix("?")
        }
        return set
    }

    // MARK: 5. HTML

    static func escapeHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func toHTML(_ plaintext: String) -> String {
        if plaintext.isEmpty { return "" }
        enum Kind { case none, ol, ul }
        var html = ""
        var para: [String] = []
        var list: Kind = .none
        var hadBlock = false

        func flushPara() {
            if para.isEmpty { return }
            html += "<p>" + para.map(escapeHTML).joined(separator: "<br>") + "</p>"
            para.removeAll()
        }
        func closeList() {
            if list == .ol { html += "</ol>" } else if list == .ul { html += "</ul>" }
            list = .none
        }
        for line in plaintext.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                flushPara(); closeList(); continue
            }
            if let r = line.range(of: "^\\d+\\.\\s+", options: .regularExpression) {
                flushPara()
                if list != .ol { closeList(); html += "<ol>"; list = .ol }
                html += "<li>" + escapeHTML(String(line[r.upperBound...])) + "</li>"
                hadBlock = true
            } else if line.hasPrefix("- ") {
                flushPara()
                if list != .ul { closeList(); html += "<ul>"; list = .ul }
                html += "<li>" + escapeHTML(String(line.dropFirst(2))) + "</li>"
                hadBlock = true
            } else {
                closeList()
                para.append(line)
                hadBlock = true
            }
        }
        flushPara(); closeList()
        return hadBlock ? html : ""
    }

    // MARK: 6. Proper noun start

    static func startsWithProperNoun(_ text: String, ini: InitInfo, ctx: ContextInfo) -> Bool {
        guard let first = text.split(whereSeparator: { $0 == " " || $0 == "\n" }).first else { return false }
        let bare = first.trimmingCharacters(in: .punctuationCharacters)
        if bare == "I" || bare.hasPrefix("I'") { return true }
        let lw = bare.lowercased()
        var set = Set<String>()
        for t in ini.vocabulary + ini.userNameWords + ctx.screenWords {
            for w in t.split(separator: " ") { set.insert(w.lowercased()) }
        }
        return set.contains(lw)
    }

    // MARK: Stats

    /// Word-level edit counts between the raw transcript and the final text.
    static func editStats(raw: String, finalText: String) -> (deletions: Int, substitutions: Int) {
        let a = words(raw), b = words(finalText)
        if a.isEmpty || b.isEmpty || a.count > 600 || b.count > 600 { return (0, 0) }
        let n = a.count, m = b.count
        var dp = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in 0...n { dp[i][0] = i }
        for j in 0...m { dp[0][j] = j }
        if n >= 1 && m >= 1 {
            for i in 1...n {
                for j in 1...m {
                    let cost = a[i - 1] == b[j - 1] ? 0 : 1
                    dp[i][j] = min(dp[i - 1][j] + 1, dp[i][j - 1] + 1, dp[i - 1][j - 1] + cost)
                }
            }
        }
        var i = n, j = m, del = 0, sub = 0
        while i > 0 || j > 0 {
            if i > 0 && j > 0 && dp[i][j] == dp[i - 1][j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1) {
                if a[i - 1] != b[j - 1] { sub += 1 }
                i -= 1; j -= 1
            } else if i > 0 && dp[i][j] == dp[i - 1][j] + 1 {
                del += 1; i -= 1
            } else {
                j -= 1
            }
        }
        return (del, sub)
    }
}
