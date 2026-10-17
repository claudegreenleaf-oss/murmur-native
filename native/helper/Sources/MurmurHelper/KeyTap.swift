import ApplicationServices
import Foundation

/// Marks events we post ourselves so the tap lets them through untouched.
let synthMarker: Int64 = 0x4D55_524D

enum Shared {
    static let dictationActive = Locked(false)
}

final class KeyTap {
    static let shared = KeyTap()

    private let combos = Locked<[Combo]>([])
    private let tapRef = Locked<CFMachPort?>(nil)
    private let staleToClear = Locked<Set<Int>>([])
    private let reportQueue = DispatchQueue(label: "murmur.helper.keyreport")
    private var held = Set<Int>()
    private var swallowed = Set<Int>()
    private var index = 0
    private var started = false
    private var watchdog: DispatchSourceTimer?

    func setCombos(_ c: [Combo]) { combos.set(c) }

    func start() {
        if started { return }
        started = true
        let t = Thread { [self] in runTap() }
        t.name = "murmur.helper.keytap"
        t.qualityOfService = .userInteractive
        t.start()
        let w = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "murmur.helper.tapwatchdog"))
        w.schedule(deadline: .now() + 1, repeating: 1)
        w.setEventHandler { [weak self] in self?.watchdogTick() }
        w.resume()
        watchdog = w
    }

    private func watchdogTick() {
        guard let tap = tapRef.get() else { return }
        if !CGEvent.tapIsEnabled(tap: tap) {
            CGEvent.tapEnable(tap: tap, enable: true)
            hlog("Keyboard service event tap disabled, attempting to restart tap")
            IPC.shared.send("TapRecoveryEvent", ["disableType": "watchdog_detected", "reason": "reenabled_watchdog"])
        }
    }

    private func runTap() {
        func bit(_ t: CGEventType) -> CGEventMask { CGEventMask(1) << CGEventMask(t.rawValue) }
        let mask: CGEventMask = bit(.keyDown) | bit(.keyUp) | bit(.flagsChanged) | bit(.otherMouseDown) | bit(.otherMouseUp)
        let callback: CGEventTapCallBack = { _, type, event, _ in
            KeyTap.shared.handle(type: type, event: event)
        }
        while true {
            if !CGPreflightListenEventAccess() {
                hlog("Keyboard service event tap created with denied preflight")
            }
            guard let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: mask,
                callback: callback,
                userInfo: nil
            ) else {
                hlog("Failed to create event tap")
                sleepMs(2000)
                continue
            }
            tapRef.set(tap)
            let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            hlog("event tap running")
            CFRunLoopRun()
            tapRef.set(nil)
            sleepMs(500)
        }
    }

    private func report(_ eventType: String, _ key: Int, _ inputType: String) {
        index += 1
        let i = index
        reportQueue.async {
            IPC.shared.send("KeypressEvent", [
                "eventType": eventType, "key": key, "index": i, "inputType": inputType,
            ])
        }
    }

    private func genericFlag(_ code: Int) -> CGEventFlags? {
        switch code {
        case 59, 62: return .maskControl
        case 56, 60: return .maskShift
        case 58, 61: return .maskAlternate
        case 55, 54: return .maskCommand
        default: return nil
        }
    }

    private func matches(_ combo: Combo, pressed code: Int) -> Bool {
        guard combo.slots.contains(where: { $0.contains(code) }) else { return false }
        var usedPressed = false
        for slot in combo.slots {
            if !usedPressed && slot.contains(code) {
                usedPressed = true
                continue
            }
            if slot.isDisjoint(with: held) { return false }
        }
        return true
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = tapRef.get() { CGEvent.tapEnable(tap: tap, enable: true) }
            held.removeAll()
            swallowed.removeAll()
            let kind = type == .tapDisabledByTimeout ? "timeout" : "user_input"
            hlog("event tap disabled by \(kind), re-enabled")
            IPC.shared.send("TapRecoveryEvent", ["disableType": kind, "reason": "reenabled_callback"])
            return pass
        }
        if event.getIntegerValueField(.eventSourceUserData) == synthMarker { return pass }

        let stale = staleToClear.mutate { s -> Set<Int> in
            let c = s
            s.removeAll()
            return c
        }
        if !stale.isEmpty { held.subtract(stale) }

        let list = combos.get()
        let active = Shared.dictationActive.get()

        switch type {
        case .keyDown:
            let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            if isRepeat { return swallowed.contains(code) ? nil : pass }
            held.insert(code)
            report("key_event_press", code, "keyboard")
            if code == Key.esc {
                if active {
                    swallowed.insert(code)
                    return nil
                }
                return pass
            }
            if list.contains(where: { !$0.hasEsc && matches($0, pressed: code) }) {
                swallowed.insert(code)
                return nil
            }
            return pass

        case .keyUp:
            let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
            if held.remove(code) != nil { report("key_event_release", code, "keyboard") }
            if swallowed.remove(code) != nil { return nil }
            return pass

        case .flagsChanged:
            let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
            guard Key.modifierCodes.contains(code) else { return pass }
            let flags = event.flags
            let down: Bool
            if code == Key.fn {
                down = flags.contains(.maskSecondaryFn)
            } else if code == Key.capsLock {
                down = flags.contains(.maskAlphaShift)
            } else if let dm = Key.deviceMask[code], let generic = genericFlag(code) {
                let allDevice: UInt64 = 0x1 | 0x2 | 0x4 | 0x8 | 0x10 | 0x20 | 0x40 | 0x2000
                down = (flags.rawValue & dm) != 0 || ((flags.rawValue & allDevice) == 0 && flags.contains(generic))
            } else {
                return pass
            }
            if down != held.contains(code) {
                if down { held.insert(code) } else { held.remove(code) }
                report(down ? "key_event_press" : "key_event_release", code, "keyboard")
            }
            if code == Key.fn && list.contains(where: { $0.hasFn }) { return nil }
            return pass

        case .otherMouseDown, .otherMouseUp:
            let btn = Int(event.getIntegerValueField(.mouseEventButtonNumber))
            if type == .otherMouseDown { held.insert(4096 + btn) } else { held.remove(4096 + btn) }
            report(type == .otherMouseDown ? "mouse_event_press" : "mouse_event_release", 1000 + btn, "mouse")
            return pass

        default:
            return pass
        }
    }

    /// Keycodes the app believes are down but the hardware says are up.
    func staleKeys(_ codes: [Int]) -> [Int] {
        var stale = [Int]()
        let flags = CGEventSource.flagsState(.hidSystemState)
        for c in codes {
            let down: Bool
            if c >= 1000 {
                guard let b = CGMouseButton(rawValue: UInt32(c - 1000)) else { continue }
                down = CGEventSource.buttonState(.hidSystemState, button: b)
            } else if c == Key.fn {
                down = flags.contains(.maskSecondaryFn)
            } else if c == Key.capsLock {
                down = flags.contains(.maskAlphaShift)
            } else {
                down = CGEventSource.keyState(.hidSystemState, key: CGKeyCode(c))
            }
            if !down { stale.append(c) }
        }
        if !stale.isEmpty { staleToClear.mutate { $0.formUnion(stale) } }
        return stale
    }
}
