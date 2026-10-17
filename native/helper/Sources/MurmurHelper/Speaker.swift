import ApplicationServices
import AppKit
import Foundation

/// Polls a meeting app's Accessibility tree for the active speaker tile and reports changes.
final class SpeakerPoller {
    static let shared = SpeakerPoller()

    private struct Config {
        var platform = ""
        var sessionId = ""
        var markers: [String] = []
        var tiles: [String] = []
        var collectNames = true
        var pid: pid_t?
    }

    private struct Tile {
        var names: [String] = []
        var speaking = false
        var muted = false
        var isSelf = false
    }

    private let queue = DispatchQueue(label: "murmur.helper.speakers", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private var config = Config()
    private var lastKey: String?

    func start(_ p: JSON) {
        queue.async { [self] in
            stopLocked()
            var c = Config()
            c.platform = p["platform"] as? String ?? ""
            c.sessionId = p["sessionId"] as? String ?? ""
            c.markers = (p["markerClasses"] as? [String]) ?? []
            c.tiles = (p["tileRootClasses"] as? [String]) ?? []
            c.collectNames = (p["collectSpeakerNames"] as? Bool) ?? true
            if let n = p["targetProcessId"] as? NSNumber { c.pid = pid_t(n.int32Value) }
            config = c
            lastKey = nil
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now(), repeating: .milliseconds(400))
            t.setEventHandler { [weak self] in self?.tick() }
            t.resume()
            timer = t
        }
    }

    func stop() {
        queue.async { [self] in stopLocked() }
    }

    private func stopLocked() {
        timer?.cancel()
        timer = nil
        lastKey = nil
    }

    private func targetApp() -> NSRunningApplication? {
        if let pid = config.pid, let a = NSRunningApplication(processIdentifier: pid) { return a }
        let wanted: [String: [String]] = [
            "zoom": ["us.zoom.xos"],
            "teams": ["com.microsoft.teams2", "com.microsoft.teams"],
            "slack": ["com.tinyspeck.slackmacgap", "com.slack.Slack"],
        ]
        if let ids = wanted[config.platform] {
            for id in ids {
                if let a = NSRunningApplication.runningApplications(withBundleIdentifier: id).first { return a }
            }
        }
        if let f = NSWorkspace.shared.frontmostApplication, AppKinds.isBrowserLike(f) { return f }
        return nil
    }

    private func source() -> String {
        switch config.platform {
        case "zoom": return "zoom_main"
        case "google_meet": return "meet_tab"
        case "teams": return "teams_main"
        default: return "slack_window"
        }
    }

    private func classes(_ v: CFTypeRef?) -> [String] {
        if let a = v as? [String] { return a }
        if let s = v as? String { return s.split(separator: " ").map(String.init) }
        return []
    }

    // Label predicates found in the reference helper: a label counts as a speaking indicator when its
    // lowercased text contains "talking", "speaking" or "active speaker"; it counts as muted when it
    // contains "muted" without being "unmuted".
    private func isSpeakingLabel(_ l: String) -> Bool {
        let t = l.lowercased()
        return t.contains("talking") || t.contains("speaking") || t.contains("active speaker")
    }

    private func isMutedLabel(_ l: String) -> Bool {
        let t = l.lowercased()
        return t.contains("muted") && !t.contains("unmuted")
    }

    private static let overflowRegex = try? NSRegularExpression(pattern: #"^\+?\d+\s+(more|others?|participants?)$"#, options: [.caseInsensitive])
    private static let timerRegex = try? NSRegularExpression(pattern: #"\d:\d\d"#)
    private static let pageRegex = try? NSRegularExpression(pattern: #"\d+\s*/\s*\d+\s*$"#)
    private static let trailingParen = try? NSRegularExpression(pattern: #"\s*\([^()]*\)\s*$"#)

    private func matches(_ re: NSRegularExpression?, _ s: String) -> Bool {
        guard let re else { return false }
        return re.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil
    }

    /// True when the label is chrome rather than a participant name.
    private func isNoise(_ l: String) -> Bool {
        let t = l.lowercased()
        if t.isEmpty || t.count > 80 { return true }
        if isSpeakingLabel(t) || t.contains("muted") || t.contains("video") || t.contains("camera") { return true }
        if matches(SpeakerPoller.overflowRegex, l) || matches(SpeakerPoller.timerRegex, l) || matches(SpeakerPoller.pageRegex, l) { return true }
        return ["pin", "more actions", "presenting", "you are speaking"].contains(t)
    }

    private func isSelfLabel(_ l: String) -> Bool {
        let t = l.lowercased()
        return t.contains("(you)") || t.hasPrefix("you,") || t == "you"
    }

    /// Display name from a tile label: first comma part, no "(You)" or trailing parenthetical.
    private func cleanName(_ l: String) -> String {
        var n = l.components(separatedBy: ",").first ?? l
        n = n.replacingOccurrences(of: "(you)", with: "", options: .caseInsensitive)
        if let re = SpeakerPoller.trailingParen {
            n = re.stringByReplacingMatches(in: n, range: NSRange(location: 0, length: (n as NSString).length), withTemplate: "")
        }
        return n.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func tick() {
        guard AXIsProcessTrusted() else { return emit(state: "unknown", speaking: [], reason: "read_failed", muted: nil, selfName: nil) }
        guard let app = targetApp() else {
            return emit(state: "unknown", speaking: [], reason: "source_missing", muted: nil, selfName: nil)
        }
        AppKinds.ensureAccessibility(app)
        let ael = axAppElement(app.processIdentifier)
        let windows = (axCopy(ael, "AXWindows") as? [AXUIElement]) ?? []
        if windows.isEmpty {
            return emit(state: "unknown", speaking: [], reason: "source_hidden", muted: nil, selfName: nil)
        }
        let isZoom = config.platform == "zoom"
        let attrs = ["AXDOMClassList", axaDesc, axaTitle, axaValue, axaChildren, "AXVisibleChildren"]
        var tiles: [Tile] = []
        var labelsByTile: [[String]] = []
        var budget = 4000
        let deadline = monoMs() + 250
        var timedOut = false

        func labels(_ v: [CFTypeRef?]) -> [String] {
            (1...3).compactMap { v[$0] as? String }.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        }

        // Depth-first walk; tileIndex is the tile the current node sits in.
        func walk(_ el: AXUIElement, _ tileIndex: Int?, _ depth: Int) {
            if budget <= 0 || monoMs() > deadline {
                timedOut = true
                return
            }
            budget -= 1
            let v = axMulti(el, attrs)
            let cls = classes(v[0])
            let ls = labels(v)
            var idx = tileIndex
            if isZoom {
                // A Zoom participant tile announces its audio state: "<name>, Computer audio (un)muted, ...".
                if ls.contains(where: { $0.lowercased().contains("audio muted") || $0.lowercased().contains("audio unmuted") }) {
                    tiles.append(Tile())
                    labelsByTile.append([])
                    idx = tiles.count - 1
                }
            } else if !cls.isEmpty, config.tiles.contains(where: { cls.contains($0) }) {
                tiles.append(Tile())
                labelsByTile.append([])
                idx = tiles.count - 1
            }
            if let i = idx {
                if !cls.isEmpty, config.markers.contains(where: { cls.contains($0) }) { tiles[i].speaking = true }
                for l in ls {
                    if isSpeakingLabel(l) { tiles[i].speaking = true }
                    if isMutedLabel(l) { tiles[i].muted = true }
                    if !labelsByTile[i].contains(l) { labelsByTile[i].append(l) }
                }
            }
            if depth > 40 { return }
            let kids = (v[5] as? [AXUIElement]) ?? (v[4] as? [AXUIElement]) ?? []
            for k in kids { walk(k, idx, depth + 1) }
        }
        for w in windows { walk(w, nil, 0) }

        if tiles.isEmpty {
            let reason = isZoom ? "indicator_unavailable" : (timedOut ? "partial_tree" : "source_missing")
            return emit(state: "unknown", speaking: [], reason: reason, muted: nil, selfName: nil)
        }
        for i in tiles.indices {
            let ls = labelsByTile[i]
            // Zoom: the label that carries the audio state also carries the name.
            let nameLabel = isZoom
                ? ls.first(where: { $0.lowercased().contains("audio") })
                : ls.first(where: { !isNoise($0) })
            if let nl = nameLabel {
                tiles[i].isSelf = isSelfLabel(nl)
                let n = cleanName(nl)
                if !n.isEmpty { tiles[i].names = [n] }
            }
        }
        let speakingTiles = tiles.filter { $0.speaking }
        let speakingNames = speakingTiles.compactMap { $0.names.first }
        let mutedNames = tiles.filter { $0.muted }.compactMap { $0.names.first }
        let selfName = tiles.first(where: { $0.isSelf })?.names.first
        let state = speakingTiles.count == 1 ? "matched" : (speakingTiles.count > 1 ? "ambiguous" : "unknown")
        emit(state: state, speaking: speakingNames, reason: speakingTiles.isEmpty ? "indicator_unavailable" : (timedOut ? "partial_coverage" : nil),
             muted: mutedNames, selfName: selfName)
    }

    private func emit(state: String, speaking: [String], reason: String?, muted: [String]?, selfName: String?) {
        let key = "\(state)|\(speaking.joined(separator: ","))|\((muted ?? []).joined(separator: ","))|\(selfName ?? "")|\(reason ?? "")"
        if key == lastKey { return }
        lastKey = key
        var p: JSON = [
            "timestamp": Int(Date().timeIntervalSince1970 * 1000),
            "attributionState": state,
            "discoveryTier": "anchored",
            "speakingNames": speaking,
            "mutedNames": NSNull(),
            "selfName": selfName ?? NSNull(),
            "source": source(),
        ]
        if let m = muted { p["mutedNames"] = m }
        if let first = speaking.first, state == "matched" { p["speakerName"] = first }
        if let r = reason, state != "matched" { p["reason"] = r }
        IPC.shared.send("MeetingSpeakerChange", p)
    }
}

enum RunningApps {
    static func list() -> JSON {
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.map { a -> JSON in
            ["name": a.localizedName ?? "", "bundleId": a.bundleIdentifier ?? "", "pid": Int(a.processIdentifier)]
        }
        return ["apps": apps]
    }
}
