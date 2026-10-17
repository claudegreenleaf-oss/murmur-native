import Foundation

/// Deterministic cleanup used when the language model is unavailable, times out, or is rejected
/// by the hallucination guard.
enum RuleCleanup {
    private static func rx(_ p: String, _ opts: NSRegularExpression.Options = [.caseInsensitive]) -> NSRegularExpression {
        // Patterns are literals in this file; a failure here is a programming error.
        try! NSRegularExpression(pattern: p, options: opts)
    }

    private static let fillers = rx("(?<![\\p{L}\\p{N}'-])(?:um+|uh+|erm|er|ah+|hmm+|mm+|uh-huh)(?![\\p{L}\\p{N}'-])[,.]?\\s*")
    private static let stutter = rx("\\b([\\p{L}']+)(\\s+\\1\\b)+")
    private static let numberish = "(?:\\d[\\d:.,]*(?:\\s?(?:am|pm|a\\.m\\.|p\\.m\\.))?|zero|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|monday|tuesday|wednesday|thursday|friday|saturday|sunday|january|february|march|april|may|june|july|august|september|october|november|december)"
    private static let backtrack = rx("(?<![\\p{L}\\p{N}])(\(numberish))[,]?\\s+(?:actually|i mean|no wait|wait no|sorry|or rather|no make that|no, make that)[,]?\\s+(\(numberish))(?![\\p{L}\\p{N}])")
    private static let interrogatives: Set<String> = [
        "what", "how", "why", "when", "where", "who", "which", "is", "are", "can", "could", "do", "does", "did",
        "will", "would", "should", "have", "has", "am", "was", "were",
    ]

    static func clean(_ raw: String, style: String = "formal", format: String = "ai") -> String {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return "" }

        t = replace(t, backtrack, "$2")
        t = applyScratch(t)
        t = replace(t, fillers, "")
        t = replace(t, stutter, "$1")
        t = spokenPunctuation(t)

        // Tidy spacing around punctuation.
        t = replace(t, rx(" +([,.;:!?])"), "$1")
        t = replace(t, rx("([,.;:!?])(?=[\\p{L}\\p{N}])"), "$1 ")
        t = replace(t, rx("[ \\t]{2,}"), " ")
        t = replace(t, rx(" *\\n *"), "\n")
        t = replace(t, rx("^[,;:\\s]+"), "")
        t = replace(t, rx(",\\s*([.!?])"), "$1")
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return "" }

        t = fixI(t)
        t = capitalizeSentences(t)

        let lowerStyle = style == "very_casual"
        if !endsWithTerminal(t) && !t.hasSuffix("\n") {
            let lastSentence = t.components(separatedBy: CharacterSet(charactersIn: ".!?\n")).last(where: {
                !$0.trimmingCharacters(in: .whitespaces).isEmpty
            }) ?? t
            let firstWord = lastSentence.trimmingCharacters(in: .whitespaces)
                .split(separator: " ").first.map { $0.lowercased() } ?? ""
            let isQuestion = interrogatives.contains(firstWord) && lastSentence.split(separator: " ").count >= 3
            if isQuestion {
                t += "?"
            } else if style == "formal" || style == "excited" {
                t += "."
            }
        }
        if lowerStyle || format == "all_lowercase" { t = t.lowercased() }
        return t
    }

    private static func replace(_ s: String, _ re: NSRegularExpression, _ template: String) -> String {
        re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
    }

    private static func applyScratch(_ s: String) -> String {
        // "I am late scratch that I am on time" -> drop the clause before the cue.
        guard let re = try? NSRegularExpression(
            pattern: "[^.!?\\n]*?\\b(?:scratch that|delete that|strike that)\\b[,.]?\\s*", options: [.caseInsensitive])
        else { return s }
        return re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
    }

    private static func spokenPunctuation(_ s: String) -> String {
        var t = s
        let pairs: [(String, String)] = [
            ("\\bnew paragraph\\b[,.]?", "\n\n"),
            ("\\bnew line\\b[,.]?", "\n"),
            ("\\bquestion mark\\b", "?"),
            ("\\bexclamation (?:point|mark)\\b", "!"),
            ("\\bfull stop\\b", "."),
            ("\\bsemicolon\\b", ";"),
            ("(?<=\\p{L})[,.]?\\s+comma\\b[,.]?", ","),
            ("(?<=\\p{L})[,.]?\\s+colon\\b[,.]?(?=\\s)", ":"),
            ("(?<=\\p{L})[,.]?\\s+period\\b[,.]?\\s*$", "."),
            ("(?<=\\p{L})[,.]?\\s+period\\b[,.]?(?=\\s*\\n)", "."),
        ]
        for (p, r) in pairs {
            t = replace(t, rx(p), r)
        }
        return t
    }

    private static func fixI(_ s: String) -> String {
        replace(s, rx("(?<![\\p{L}\\p{N}'])i(?=(?:'(?:m|ll|ve|d))?(?![\\p{L}\\p{N}']))", []), "I")
    }

    private static func capitalizeSentences(_ s: String) -> String {
        var out = ""
        var capNext = true
        for ch in s {
            if capNext, ch.isLetter {
                out += String(ch).uppercased()
                capNext = false
            } else {
                out.append(ch)
                if ch == "." || ch == "!" || ch == "?" || ch == "\n" { capNext = true }
                else if ch.isLetter || ch.isNumber { capNext = false }
            }
        }
        return out
    }

    private static func endsWithTerminal(_ s: String) -> Bool {
        guard let last = s.last else { return true }
        return ".!?:;".contains(last)
    }
}
