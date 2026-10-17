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

    private func tick() {
        guard AXIsProcessTrusted() else { return emit(state: "unknown", speaking: [], reason: "read_failed", names: nil, selfName: nil) }
        guard let app = targetApp() else {
            return emit(state: "unknown", speaking: [], reason: "source_missing", names: nil, selfName: nil)
        }
        AppKinds.ensureAccessibility(app)
        let ael = axAppElement(app.processIdentifier)
        let windows = (axCopy(ael, "AXWindows") as? [AXUIElement]) ?? []
        if windows.isEmpty {
            return emit(state: "unknown", speaking: [], reason: "source_hidden", names: nil, selfName: nil)
        }
        if config.platform == "zoom" {
            // Native Zoom exposes no indicator we can read reliably.
            return emit(state: "unknown", speaking: [], reason: "indicator_unavailable", names: nil, selfName: nil)
        }

        let attrs = ["AXDOMClassList", axaValue, axaTitle, axaDesc, axaChildren, "AXVisibleChildren"]
        var tiles: [Tile] = []
        var budget = 4000
        let deadline = monoMs() + 250
        var timedOut = false

        // Depth-first walk; tileIndex is the tile the current node sits in.
        func walk(_ el: AXUIElement, _ tileIndex: Int?, _ depth: Int) {
            if budget <= 0 || monoMs() > deadline {
                timedOut = true
                return
            }
            budget -= 1
            let v = axMulti(el, attrs)
            let cls = classes(v[0])
            var idx = tileIndex
            if !cls.isEmpty, config.tiles.contains(where: { cls.contains($0) }) {
                tiles.append(Tile())
                idx = tiles.count - 1
            }
            if let i = idx {
                if !cls.isEmpty, config.markers.contains(where: { cls.contains($0) }) { tiles[i].speaking = true }
                if config.collectNames {
                    for k in 1...3 {
                        if let s = v[k] as? String {
                            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !t.isEmpty && t.count <= 80 && !tiles[i].names.contains(t) { tiles[i].names.append(t) }
                        }
                    }
                }
            }
            if depth > 40 { return }
            let kids = (v[5] as? [AXUIElement]) ?? (v[4] as? [AXUIElement]) ?? []
            for k in kids { walk(k, idx, depth + 1) }
        }
        for w in windows { walk(w, nil, 0) }

        if tiles.isEmpty {
            return emit(state: "unknown", speaking: [], reason: timedOut ? "partial_tree" : "source_missing", names: nil, selfName: nil)
        }
        func label(_ t: Tile) -> String? {
            // First short text that is not a status word.
            let skip: Set<String> = ["muted", "unmuted", "pin", "more actions", "presenting"]
            return t.names.first { !skip.contains($0.lowercased()) }
        }
        let speakingTiles = tiles.filter { $0.speaking }
        let names = speakingTiles.compactMap(label)
        var selfName: String?
        for t in tiles {
            if let l = label(t), t.names.contains(where: { $0.lowercased() == "you" || $0.lowercased().hasSuffix("(you)") }) {
                selfName = l.replacingOccurrences(of: " (You)", with: "")
                break
            }
        }
        let state = speakingTiles.count == 1 ? "matched" : (speakingTiles.count > 1 ? "ambiguous" : "unknown")
        emit(state: state, speaking: names, reason: speakingTiles.isEmpty ? "indicator_unavailable" : (timedOut ? "partial_coverage" : nil),
             names: nil, selfName: selfName)
    }

    private func emit(state: String, speaking: [String], reason: String?, names: [String]?, selfName: String?) {
        let key = "\(state)|\(speaking.joined(separator: ","))|\(selfName ?? "")|\(reason ?? "")"
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
