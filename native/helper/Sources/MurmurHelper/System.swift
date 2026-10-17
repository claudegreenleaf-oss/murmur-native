import ApplicationServices
import AppKit
import Carbon.HIToolbox
import Foundation
import IOKit

// MARK: secure input

final class SecureInputMonitor {
    static let shared = SecureInputMonitor()

    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "murmur.helper.secureinput")
    private var last: (blocked: Bool, pid: Int?)?

    static func current() -> (blocked: Bool, pid: Int?) {
        let blocked = IsSecureEventInputEnabled()
        var pid: Int?
        if blocked, let d = CGSessionCopyCurrentDictionary() as? [String: Any] {
            pid = d["kCGSSessionSecureInputPID"] as? Int
        }
        return (blocked, pid)
    }

    func start() {
        if timer != nil { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
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

    private func tick() {
        let cur = SecureInputMonitor.current()
        if let l = last, l.blocked == cur.blocked, l.pid == cur.pid { return }
        last = cur
        var payload: JSON = ["blocked": cur.blocked]
        if cur.blocked, let pid = cur.pid {
            payload["ownerPid"] = pid
            if let app = NSRunningApplication(processIdentifier: pid_t(pid)) {
                if let n = app.localizedName { payload["ownerAppName"] = n }
                if let b = app.bundleIdentifier { payload["ownerBundleId"] = b }
            }
        }
        IPC.shared.send("SecureInputStatus", payload)
    }
}

// MARK: hardware

enum Hardware {
    private static func prop(_ e: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(e, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    static func hasAppleFnKey() -> Bool {
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOHIDDevice"), &iter) == KERN_SUCCESS else {
            return true
        }
        defer { IOObjectRelease(iter) }
        var sawKeyboard = false
        var sawApple = false
        var e = IOIteratorNext(iter)
        while e != 0 {
            let page = prop(e, "PrimaryUsagePage") as? Int
            let usage = prop(e, "PrimaryUsage") as? Int
            if page == 1 && usage == 6 {
                sawKeyboard = true
                if (prop(e, "VendorID") as? Int) == 1452 { sawApple = true }
            }
            IOObjectRelease(e)
            e = IOIteratorNext(iter)
        }
        if !sawKeyboard { return true }
        if !sawApple { hlog("Found an external non-Apple keyboard. Assuming no Fn key available.") }
        return sawApple
    }

    static func isClamshell() -> Bool {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard svc != 0 else { return false }
        defer { IOObjectRelease(svc) }
        return (prop(svc, "AppleClamshellState") as? Bool) ?? false
    }

    static func info() -> JSON {
        ["hasAppleFnKey": hasAppleFnKey(), "isClamshellMode": isClamshell()]
    }
}

final class HardwareMonitor {
    static let shared = HardwareMonitor()
    private var timer: DispatchSourceTimer?
    private var last: (Bool, Bool)?

    func start() {
        if timer != nil { return }
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "murmur.helper.hardware"))
        t.schedule(deadline: .now(), repeating: 3)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            let cur = (Hardware.hasAppleFnKey(), Hardware.isClamshell())
            if let l = self.last, l == cur { return }
            self.last = cur
            IPC.shared.send("HardwareInfoUpdate", ["hasAppleFnKey": cur.0, "isClamshellMode": cur.1])
        }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel()
        timer = nil
        last = nil
    }
}

// MARK: permissions

enum Perms {
    static func status() -> JSON {
        [
            "status": AXIsProcessTrusted(),
            "inputMonitoring": CGPreflightListenEventAccess(),
            "postEvent": CGPreflightPostEventAccess(),
        ]
    }

    static func request() {
        DispatchQueue.main.async {
            let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(opts)
            if !CGPreflightListenEventAccess() { _ = CGRequestListenEventAccess() }
            if !CGPreflightPostEventAccess() { _ = CGRequestPostEventAccess() }
        }
    }
}

// MARK: synthetic keys

enum Synth {
    static func post(keycode: Int, flags: CGEventFlags = [], source: CGEventSource? = nil) {
        let src = source ?? CGEventSource(stateID: .privateState)
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(keycode), keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(keycode), keyDown: false)
        else { return }
        down.flags = flags
        up.flags = flags
        down.setIntegerValueField(.eventSourceUserData, value: synthMarker)
        up.setIntegerValueField(.eventSourceUserData, value: synthMarker)
        down.post(tap: .cghidEventTap)
        sleepMs(4)
        up.post(tap: .cghidEventTap)
    }

    /// Cmd + <character> using the keycode that produces `char` on the ASCII-capable layout.
    static func command(_ char: String, fallback: Int) {
        let src = CGEventSource(stateID: .privateState)
        let code = layoutKeyCode(char) ?? fallback
        func ev(_ k: Int, _ d: Bool, _ f: CGEventFlags) -> CGEvent? {
            let e = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(k), keyDown: d)
            e?.flags = f
            e?.setIntegerValueField(.eventSourceUserData, value: synthMarker)
            return e
        }
        ev(0x37, true, .maskCommand)?.post(tap: .cghidEventTap)
        sleepMs(4)
        ev(code, true, .maskCommand)?.post(tap: .cghidEventTap)
        sleepMs(4)
        ev(code, false, .maskCommand)?.post(tap: .cghidEventTap)
        sleepMs(4)
        ev(0x37, false, [])?.post(tap: .cghidEventTap)
    }

    static func flags(from names: [String]) -> CGEventFlags {
        var f: CGEventFlags = []
        for n in names {
            switch n.lowercased() {
            case "command", "cmd", "meta": f.insert(.maskCommand)
            case "shift": f.insert(.maskShift)
            case "control", "ctrl": f.insert(.maskControl)
            case "option", "alt", "opt": f.insert(.maskAlternate)
            case "function", "fn": f.insert(.maskSecondaryFn)
            case "capslock", "caps_lock": f.insert(.maskAlphaShift)
            default: break
            }
        }
        return f
    }

    private static func layoutKeyCode(_ char: String) -> Int? {
        func compute() -> Int? {
            guard let srcRef = TISCopyCurrentASCIICapableKeyboardLayoutInputSource() else { return nil }
            let src = srcRef.takeRetainedValue()
            guard let ptr = TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData) else { return nil }
            let data = unsafeBitCast(ptr, to: CFData.self)
            guard let bytes = CFDataGetBytePtr(data) else { return nil }
            let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
            for code in 0..<128 {
                var dead: UInt32 = 0
                var chars = [UniChar](repeating: 0, count: 4)
                var len = 0
                let st = UCKeyTranslate(
                    layout, UInt16(code), UInt16(kUCKeyActionDown), 0, UInt32(LMGetKbdType()),
                    UInt32(kUCKeyTranslateNoDeadKeysMask), &dead, chars.count, &len, &chars
                )
                if st == noErr, len > 0 {
                    let s = String(utf16CodeUnits: chars, count: len)
                    if s.lowercased() == char { return code }
                }
            }
            return nil
        }
        // TIS calls must run on the main queue on recent macOS.
        if Thread.isMainThread { return compute() }
        return DispatchQueue.main.sync { compute() }
    }
}
