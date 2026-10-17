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

    private func fail(_ retryable: Bool) -> JSON {
        ["browserAnchored": false, "retryable": retryable]
    }

    private func standardWindow(_ ael: AXUIElement) -> AXUIElement? {
        let wins = (axCopy(ael, "AXWindows") as? [AXUIElement]) ?? []
        let std = wins.filter { w in
            axStr(w, axaSubrole) == "AXStandardWindow" && (axCopy(w, "AXMinimized") as? Bool) != true
        }
        if let f = axElem(ael, axaFocusedWindow), std.contains(where: { CFEqual($0, f) }) { return f }
        return std.first
    }

    func position(name: String, mode: String, minWidth: Double, fraction: Double) -> JSON {
        guard AXIsProcessTrusted() else {
            hlog("Browser window resize skipped: not Accessibility-trusted")
            return fail(false)
        }
        let needle = name.lowercased()
        let apps = NSWorkspace.shared.runningApplications.filter { a in
            guard a.activationPolicy == .regular else { return false }
            let n = a.localizedName?.lowercased() ?? ""
            let b = a.bundleIdentifier?.lowercased() ?? ""
            return n == needle || b == needle || (!needle.isEmpty && (n.contains(needle) || b.contains(needle)))
        }.sorted { ($0.isActive ? 0 : 1) < ($1.isActive ? 0 : 1) }
        if apps.isEmpty {
            hlog("Browser window resize skipped: no running app matches requested browser name")
            return fail(true)
        }
        var found: (NSRunningApplication, AXUIElement)?
        for a in apps {
            AppKinds.ensureAccessibility(a)
            if let w = standardWindow(axAppElement(a.processIdentifier)) {
                found = (a, w)
                break
            }
        }
        guard let (app, win) = found else {
            hlog("Browser window resize skipped: no standard window")
            return fail(true)
        }
        if (axCopy(win, "AXFullScreen") as? Bool) == true {
            hlog("fullscreen_skipped")
            return fail(false)
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
                "recorderX": Int(recorder.minX.rounded()), "recorderY": Int(recorder.minY.rounded()),
                "recorderWidth": Int(recorder.width.rounded()), "recorderHeight": Int(recorder.height.rounded()),
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

        switch mode {
        case "awaitWindow":
            if close(current, browser, 8) { return result(already: true) }
        case "resplitIfMoved":
            // Only act when the user moved the window away from where we put it.
            if let l = last, close(current, l, 8) { return result(already: true) }
            if last == nil, close(current, browser, 8) { return result(already: true) }
        default:
            break
        }

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

/// Reports whether the Dock occupies screen space (a hidden Dock does not) and where it sits.
final class DockMonitor {
    static let shared = DockMonitor()

    private var timer: DispatchSourceTimer?
    private var last: (Bool, Int, Int)?

    func start() {
        if timer != nil { return }
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "murmur.helper.dock"))
        t.schedule(deadline: .now(), repeating: 1)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel()
        timer = nil
        last = nil
    }

    static func info() -> (visible: Bool, x: Int, y: Int) {
        let displays = DisplayGeometry.all()
        var best: (inset: CGFloat, rect: CGRect)?
        for d in displays {
            let left = d.workArea.minX - d.frame.minX
            let right = d.frame.maxX - d.workArea.maxX
            let bottom = d.frame.maxY - d.workArea.maxY
            let rect: CGRect
            let inset: CGFloat
            if bottom >= left && bottom >= right {
                inset = bottom
                rect = CGRect(x: d.workArea.minX, y: d.workArea.maxY, width: d.workArea.width, height: bottom)
            } else if left >= right {
                inset = left
                rect = CGRect(x: d.frame.minX, y: d.workArea.minY, width: left, height: d.workArea.height)
            } else {
                inset = right
                rect = CGRect(x: d.workArea.maxX, y: d.workArea.minY, width: right, height: d.workArea.height)
            }
            if inset > (best?.inset ?? 0) { best = (inset, rect) }
        }
        if let b = best, b.inset > 0.5 { return (true, Int(b.rect.minX.rounded()), Int(b.rect.minY.rounded())) }
        return (false, 0, 0)
    }

    private func tick() {
        let i = DockMonitor.info()
        let cur = (i.visible, i.x, i.y)
        if let l = last, l == cur { return }
        last = cur
        IPC.shared.send("DockInfoUpdate", ["isVisible": i.visible, "x": i.x, "y": i.y])
    }
}
