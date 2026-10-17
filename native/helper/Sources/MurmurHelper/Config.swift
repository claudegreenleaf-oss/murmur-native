import Foundation

enum Key {
    static let fn = 63
    static let esc = 53
    static let capsLock = 57

    /// Modifier keycode -> device-dependent flag bit in CGEventFlags.rawValue.
    static let deviceMask: [Int: UInt64] = [
        59: 0x1, 56: 0x2, 60: 0x4, 55: 0x8, 54: 0x10, 58: 0x20, 61: 0x40, 62: 0x2000,
    ]
    static let modifierCodes: Set<Int> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]

    static let named: [String: Set<Int>] = {
        var t: [String: Set<Int>] = [
            "fn": [63], "function": [63], "globe": [63],
            "ctrl": [59, 62], "control": [59, 62], "ctrl_l": [59], "ctrl_r": [62],
            "shift": [56, 60], "shift_l": [56], "shift_r": [60],
            "alt": [58, 61], "opt": [58, 61], "option": [58, 61], "opt_l": [58], "opt_r": [61], "alt_r": [61], "alt_l": [58],
            "cmd": [55, 54], "command": [55, 54], "meta": [55, 54], "cmd_l": [55], "cmd_r": [54],
            "caps_lock": [57], "capslock": [57], "caps": [57],
            "space": [49], "esc": [53], "escape": [53], "enter": [36], "return": [36], "tab": [48],
            "delete": [51], "backspace": [51], "forward_delete": [117], "home": [115], "end": [119],
            "pageup": [116], "page_up": [116], "pagedown": [121], "page_down": [121],
            "left": [123], "right": [124], "down": [125], "up": [126],
            "minus": [27], "-": [27], "equal": [24], "equals": [24], "plus": [24], "=": [24],
            "[": [33], "]": [30], ";": [41], "'": [39], "\\": [42], ",": [43], ".": [47], "/": [44], "`": [50],
        ]
        let letters: [(String, Int)] = [
            ("a", 0), ("s", 1), ("d", 2), ("f", 3), ("h", 4), ("g", 5), ("z", 6), ("x", 7), ("c", 8), ("v", 9),
            ("b", 11), ("q", 12), ("w", 13), ("e", 14), ("r", 15), ("y", 16), ("t", 17), ("o", 31), ("u", 32),
            ("i", 34), ("p", 35), ("l", 37), ("j", 38), ("k", 40), ("n", 45), ("m", 46),
        ]
        for (k, v) in letters { t[k] = [v] }
        let digits: [(String, Int)] = [
            ("1", 18), ("2", 19), ("3", 20), ("4", 21), ("6", 22), ("5", 23), ("9", 25), ("7", 26), ("8", 28), ("0", 29),
        ]
        for (k, v) in digits { t[k] = [v] }
        let fkeys: [Int] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90]
        for (i, c) in fkeys.enumerated() { t["f\(i + 1)"] = [c] }
        return t
    }()

}

struct Combo {
    let slots: [Set<Int>]
    let action: String

    var hasFn: Bool { slots.contains { $0 == [Key.fn] } }
    var hasEsc: Bool { slots.contains { $0 == [Key.esc] } }

    static func parse(_ s: String, action: String) -> Combo? {
        var tokens = s.lowercased().split(separator: "+", omittingEmptySubsequences: true).map { String($0).trimmingCharacters(in: .whitespaces) }
        if s.hasSuffix("++") { tokens.append("plus") }
        if tokens.isEmpty { return nil }
        var slots: [Set<Int>] = []
        // Canonical format: numeric macOS keycodes (4096 + n = mouse button n), exact left/right codes.
        let numeric = tokens.compactMap { Int($0) }
        if numeric.count == tokens.count {
            return Combo(slots: numeric.map { [$0] }, action: action)
        }
        for t in tokens {
            guard let codes = Key.named[t] else { return nil }
            slots.append(codes)
        }
        return Combo(slots: slots, action: action)
    }
}

struct Prefs {
    var combos: [Combo] = []
    var useAxContext = true
    var shouldPauseAudio = false
    var shouldMuteAudio = false

    static var configURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Murmur/config.json")
    }

    private static func dig(_ root: Any?, _ path: [String]) -> Any? {
        var cur = root
        for p in path {
            guard let d = cur as? JSON else { return nil }
            cur = d[p]
        }
        return cur
    }

    private static func bool(_ v: Any?) -> Bool? {
        if let b = v as? Bool { return b }
        if let n = v as? NSNumber { return n.boolValue }
        return nil
    }

    private static func strings(_ v: Any?) -> [String] {
        if let s = v as? String { return [s] }
        if let a = v as? [Any] { return a.flatMap { strings($0) } }
        if let d = v as? JSON {
            for k in ["keys", "combo", "shortcut", "key"] {
                if let x = d[k] { return strings(x) }
            }
        }
        return []
    }

    static func load() -> Prefs {
        var p = Prefs()
        guard let data = try? Data(contentsOf: configURL),
              let root = try? JSONSerialization.jsonObject(with: data) else {
            hlog("Swift Helper: Error reading config.json")
            return p
        }
        func pref(_ name: String) -> Any? {
            dig(root, ["prefs", "user", name]) ?? dig(root, [name])
        }
        if let b = bool(pref("useAxContext")) { p.useAxContext = b }
        if let b = bool(pref("shouldPauseAudio")) { p.shouldPauseAudio = b }
        if let b = bool(pref("shouldMuteAudio")) { p.shouldMuteAudio = b }
        let raw = pref("shortcuts") ?? pref("shortcutKeys")
        if let map = raw as? JSON {
            for (k, v) in map {
                if let c = Combo.parse(k, action: strings(v).first ?? k) {
                    p.combos.append(c)
                    continue
                }
                for s in strings(v) {
                    if let c = Combo.parse(s, action: k) { p.combos.append(c) }
                }
            }
        } else if let arr = raw as? [Any] {
            for item in arr {
                for s in strings(item) {
                    if let c = Combo.parse(s, action: s) { p.combos.append(c) }
                }
            }
        }
        return p
    }
}
