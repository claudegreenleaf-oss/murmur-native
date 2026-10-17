import ApplicationServices
import AppKit
import Foundation

/// Display geometry in the Accessibility coordinate space (origin top-left of the primary display).
struct DisplayGeometry {
    let frame: CGRect
    let workArea: CGRect

    static func all() -> [DisplayGeometry] {
        onMain {
            let screens = NSScreen.screens
            guard let primary = screens.first else { return [] }
            let h = primary.frame.height
            func flip(_ r: CGRect) -> CGRect { CGRect(x: r.minX, y: h - r.maxY, width: r.width, height: r.height) }
            return screens.map { DisplayGeometry(frame: flip($0.frame), workArea: flip($0.visibleFrame)) }
        }
    }
}

private func axPoint(_ el: AXUIElement, _ attr: String) -> CGPoint? {
    guard let v = axCopy(el, attr), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
    let av = unsafeBitCast(v, to: AXValue.self)
    var p = CGPoint.zero
    return AXValueGetValue(av, .cgPoint, &p) ? p : nil
}

private func axSize(_ el: AXUIElement, _ attr: String) -> CGSize? {
    guard let v = axCopy(el, attr), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
    let av = unsafeBitCast(v, to: AXValue.self)
    var s = CGSize.zero
    return AXValueGetValue(av, .cgSize, &s) ? s : nil
}

private func axSetFrame(_ el: AXUIElement, _ r: CGRect) {
    var size = r.size
    var origin = r.origin
    if let sv = AXValueCreate(.cgSize, &size) { AXUIElementSetAttributeValue(el, "AXSize" as CFString, sv) }
    if let pv = AXValueCreate(.cgPoint, &origin) { AXUIElementSetAttributeValue(el, "AXPosition" as CFString, pv) }
    if let sv = AXValueCreate(.cgSize, &size) { AXUIElementSetAttributeValue(el, "AXSize" as CFString, sv) }
}

/// Split-screen: the meeting app's window takes the left part of the work area, Murmur's recorder the right.
final class BrowserPositioner {
    static let shared = BrowserPositioner()

    private var placed: [pid_t: CGRect] = [:]
    private let lock = NSLock()

    /// Failures are retryable unless Accessibility is missing.
    private func fail(_ retryable: Bool) -> JSON {
        ["browserAnchored": false, "retryable": retryable && AXIsProcessTrusted()]
    }

    private func standardWindow(_ ael: AXUIElement, requiredIdentifier: String?) -> AXUIElement? {
        let wins = (axCopy(ael, "AXWindows") as? [AXUIElement]) ?? []
        let std = wins.filter { w in
            axStr(w, axaSubrole) == "AXStandardWindow" && (axCopy(w, "AXMinimized") as? Bool) != true
                && (requiredIdentifier == nil || axStr(w, "AXIdentifier") == requiredIdentifier)
        }
        if let f = axElem(ael, axaFocusedWindow), std.contains(where: { CFEqual($0, f) }) { return f }
        return std.first
    }

    func position(name: String, mode: String, minWidth: Double, fraction: Double) -> JSON {
        guard AXIsProcessTrusted() else {
            hlog("Browser window resize skipped: not Accessibility-trusted")
            return fail(false)
        }
        // Exact match on the localized name, then on the bundle identifier (no fuzzy matching).
        let running = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        var apps = running.filter { $0.localizedName == name }
        if apps.isEmpty { apps = running.filter { $0.bundleIdentifier == name } }
        apps.sort { ($0.isActive ? 0 : 1) < ($1.isActive ? 0 : 1) }
        if apps.isEmpty {
            hlog("Browser window resize skipped: no running app matches requested browser name")
            return fail(true)
        }
        var found: (NSRunningApplication, AXUIElement)?
        for a in apps {
            AppKinds.ensureAccessibility(a)
            // Zoom has several standard windows; only the meeting window counts.
            let required = a.bundleIdentifier == "us.zoom.xos" ? "zm.meeting.window.main" : nil
            if let w = standardWindow(axAppElement(a.processIdentifier), requiredIdentifier: required) {
                found = (a, w)
                break
            }
        }
        guard let (app, win) = found else {
            hlog("Browser window resize skipped: no standard window")
            return fail(true)
        }
        guard let pos = axPoint(win, "AXPosition"), let size = axSize(win, "AXSize") else { return fail(true) }
        let current = CGRect(origin: pos, size: size)
        let center = CGPoint(x: current.midX, y: current.midY)
        let displays = DisplayGeometry.all()
        let display = displays.first(where: { $0.frame.contains(center) })
            ?? displays.max(by: { $0.frame.intersection(current).width * $0.frame.intersection(current).height
                < $1.frame.intersection(current).width * $1.frame.intersection(current).height })
        guard let work = display?.workArea else {
            hlog("Browser window resize skipped: no display for window")
            return fail(false)
        }

        let w = Double(work.width)
        let rw = min(w, max(minWidth, (w * fraction).rounded()))
        let browser = CGRect(x: work.minX, y: work.minY, width: max(0, w - rw - 1), height: work.height)
        let recorder = CGRect(x: work.minX + CGFloat(w - rw), y: work.minY, width: CGFloat(rw), height: work.height)
        func result(already: Bool) -> JSON {
            var r: JSON = [
                "browserAnchored": true,
                "recorderX": Int(recorder.minX), "recorderY": Int(recorder.minY),
                "recorderWidth": Int(recorder.width), "recorderHeight": Int(recorder.height),
            ]
            if already { r["alreadyPlaced"] = true }
            return r
        }
        func close(_ a: CGRect, _ b: CGRect, _ tol: CGFloat) -> Bool {
            abs(a.minX - b.minX) <= tol && abs(a.minY - b.minY) <= tol
                && abs(a.width - b.width) <= tol && abs(a.height - b.height) <= tol
        }

        let pid = app.processIdentifier
        lock.lock()
        let last = placed[pid]
        lock.unlock()

        // Only resplitIfMoved short-circuits: the window is left alone while it is within 2 pt of the
        // split frame or of the frame the helper last gave it (same process). awaitWindow and split always place.
        if mode == "resplitIfMoved" {
            if close(current, browser, 2) { return result(already: true) }
            if let l = last, close(current, l, 2) { return result(already: true) }
        }

        AXUIElementPerformAction(win, "AXRaise" as CFString)
        axSetFrame(win, browser)
        sleepMs(60)
        let np = axPoint(win, "AXPosition")
        let ns = axSize(win, "AXSize")
        guard let np, let ns else { return fail(true) }
        let now = CGRect(origin: np, size: ns)
        if close(now, current, 1) && !close(now, browser, 8) {
            hlog("AX browser window frame not applied")
            return fail(true)
        }
        lock.lock()
        placed[pid] = now
        lock.unlock()
        return result(already: false)
    }
}

/// Dock window geometry from the window server, polled like the original helper: first after 100 ms,
/// then every 0.5 s, sending only on change. `isVisible` is false when no on-screen Dock window exists
/// (hidden Dock); otherwise x and y are the top-left of the Dock's on-screen window bounds.
final class DockMonitor {
    static let shared = DockMonitor()

    private var timer: DispatchSourceTimer?
    private var last: (Bool, Int, Int)?

    func start() {
        if timer != nil { return }
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "murmur.helper.dock"))
        t.schedule(deadline: .now() + .milliseconds(100), repeating: 0.5)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
        hlog("Starting to detect the dock position")
    }

    func stop() {
        timer?.cancel()
        timer = nil
        last = nil
        hlog("Stopping DockWindowObserver")
    }

    static func info() -> (visible: Bool, x: Int, y: Int) {
        // kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements
        let opts = CGWindowListOption(rawValue: 17)
        guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else {
            return (false, 0, 0)
        }
        var union: CGRect?
        for w in list where (w["kCGWindowOwnerName"] as? String) == "Dock" {
            guard let b = w["kCGWindowBounds"] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: b as CFDictionary),
                  r.width > 0, r.height > 0 else { continue }
            union = union.map { $0.union(r) } ?? r
        }
        guard let u = union else { return (false, 0, 0) }
        return (true, Int(u.minX), Int(u.minY))
    }

    private func tick() {
        let i = DockMonitor.info()
        let cur = (i.visible, i.x, i.y)
        if let l = last, l == cur { return }
        last = cur
        IPC.shared.send("DockInfoUpdate", ["isVisible": i.visible, "x": i.x, "y": i.y])
    }
}
