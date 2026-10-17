import ApplicationServices
import AppKit
import Foundation

final class HelperApp {
    static let shared = HelperApp()

    private var prefs = Prefs()
    private let axQueue = DispatchQueue(label: "murmur.helper.ax", qos: .userInitiated)
    private var storedApp: NSRunningApplication?
    private var storedElement: AXUIElement?
    private var workspaceObserver: NSObjectProtocol?

    func boot() {
        prefs = Prefs.load()
        KeyTap.shared.setCombos(prefs.combos)
        hlog("booted, \(prefs.combos.count) shortcut combos")
    }

    // MARK: dispatch

    func handle(_ name: String, _ value: Any, _ reply: @escaping (Reply) -> Void) {
        switch name {
        case "IsReady":
            reply(.ack)

        case "UpdateShortcuts":
            prefs = Prefs.load()
            KeyTap.shared.setCombos(prefs.combos)
            hlog("shortcuts updated: \(prefs.combos.count) combos")
            reply(.ack)

        case "UpdateFeatureFlags", "RecordingStarted":
            reply(.ack)

        case "StartAccessibilityServices":
            KeyTap.shared.start()
            startWorkspaceObserver()
            reply(.ack)

        case "StartAllIntervals":
            SecureInputMonitor.shared.start()
            HardwareMonitor.shared.start()
            reply(.ack)

        case "StopAllIntervals":
            SecureInputMonitor.shared.stop()
            HardwareMonitor.shared.stop()
            reply(.ack)

        case "SetSecureInputMonitor":
            if (payloadDict(value)["enabled"] as? Bool) ?? true {
                SecureInputMonitor.shared.start()
            } else {
                SecureInputMonitor.shared.stop()
            }
            reply(.ack)

        case "HelperAppShutdown":
            reply(.ack)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                hlog("shutdown requested")
                exit(0)
            }

        case "RequestAccessibilityPermission":
            Perms.request()
            reply(.ack)

        case "GetAccessibilityStatus":
            reply(.data("AccessibilityStatus", Perms.status()))

        case "GetHardwareInfo":
            reply(.data("HardwareInfo", Hardware.info()))

        case "DictationStart":
            dictationStart()
            reply(.ack)

        case "DictationStop":
            Shared.dictationActive.set(false)
            MediaManager.shared.dictationStop()
            reply(.ack)

        case "GetTextBoxInfo":
            axQueue.async { reply(.data("TextBoxInfo", readTextBox(currentFocus()).json())) }

        case "GetActiveAppInfo":
            axQueue.async {
                let focus = currentFocus()
                reply(.data("ActiveAppInfo", readAppInfo(focus: focus).json()))
            }

        case "GetSelectedTextViaCopy":
            axQueue.async { reply(.data("SelectedTextViaCopy", PasteManager.shared.selectedTextViaCopy())) }

        case "PasteText":
            reply(.ack)
            PasteManager.shared.paste(payloadDict(value))

        case "CancelPaste":
            PasteManager.shared.cancel()
            reply(.ack)

        case "SimulateKeyPress":
            let p = payloadDict(value)
            let code = (p["keycode"] as? NSNumber)?.intValue ?? 0
            let flags = Synth.flags(from: (p["flags"] as? [String]) ?? [])
            axQueue.async {
                Synth.post(keycode: code, flags: flags)
                reply(.ack)
            }

        case "StoreFocusedAppAndElement":
            axQueue.async { [self] in
                storedApp = NSWorkspace.shared.frontmostApplication
                storedElement = currentFocus()?.element
                reply(.ack)
            }

        case "FocusStoredAppAndElement":
            axQueue.async { [self] in
                focusStored()
                reply(.ack)
            }

        case "CheckStaleKeys":
            let codes = ((payloadDict(value)["keycodes"] as? [Any]) ?? []).compactMap { ($0 as? NSNumber)?.intValue }
            reply(.data("StaleKeysResponse", ["staleKeys": KeyTap.shared.staleKeys(codes)]))

        case "GetSystemAudioStatus":
            reply(.data("SystemAudioStatus", SystemAudio.status()))

        case "RequestSystemAudioPermission":
            guard #available(macOS 14.4, *) else { return reply(.data("SystemAudioPromptResult", ["result": "unavailable"])) }
            SystemAudioTap.shared.triggerPrompt { reply(.data("SystemAudioPromptResult", ["result": $0])) }

        case "StartSystemAudioCapture":
            guard #available(macOS 14.4, *) else { return reply(.error("macOS 14.4 or newer required", "UNSUPPORTED_OS")) }
            let p = payloadDict(value)
            let prefixes = (p["excludeBundleIdPrefixes"] as? [String]) ?? ["com.thomasgreenleaf.murmur"]
            let pids = ((p["excludePids"] as? [Any]) ?? []).compactMap { ($0 as? NSNumber)?.intValue }
            SystemAudioTap.shared.start(prefixes: prefixes, pids: pids) { err in
                if let err { reply(.error("System audio capture failed: \(err)", "SYSTEM_AUDIO_START_FAILED")) } else { reply(.ack) }
            }

        case "StopSystemAudioCapture":
            guard #available(macOS 14.4, *) else { return reply(.ack) }
            SystemAudioTap.shared.stop { reply(.ack) }

        case "SetMicrophoneHoldersMonitor":
            guard #available(macOS 14.4, *) else { return reply(.error("macOS 14.4 or newer required", "UNSUPPORTED_OS")) }
            let p = payloadDict(value)
            MicHoldersMonitor.shared.set(enabled: (p["enabled"] as? Bool) ?? false, cadenceMs: (p["cadenceMs"] as? NSNumber)?.intValue)
            reply(.ack)

        case "GetMicrophoneHolders":
            guard #available(macOS 14.4, *) else { return reply(.error("macOS 14.4 or newer required", "UNSUPPORTED_OS")) }
            axQueue.async { reply(.data("MicrophoneHolders", MicHoldersMonitor.shared.snapshot())) }

        case "GetCalendarAccessStatus":
            reply(.data("CalendarAccessStatus", ["status": CalendarBridge.shared.status()]))

        case "RequestCalendarAccess":
            CalendarBridge.shared.requestAccess { reply(.data("CalendarAccessStatus", ["status": $0])) }

        case "GetCalendarEvents":
            let p = payloadDict(value)
            let from = (p["fromMs"] as? NSNumber)?.doubleValue ?? 0
            let to = (p["toMs"] as? NSNumber)?.doubleValue ?? 0
            axQueue.async { reply(.data("CalendarEvents", CalendarBridge.shared.events(fromMs: from, toMs: to))) }

        default:
            reply(.error("No handler registered for \(name)", "NO_HANDLER_REGISTERED"))
        }
    }

    // MARK: dictation

    private func dictationStart() {
        prefs = Prefs.load()
        KeyTap.shared.setCombos(prefs.combos)
        Shared.dictationActive.set(true)
        EditObserver.shared.end(reason: "new_dictation")
        MediaManager.shared.dictationStart(prefs)
        let useAx = prefs.useAxContext
        axQueue.async {
            let focus = currentFocus()
            let app = readAppInfo(focus: focus)
            IPC.shared.send("AppInfoUpdate", app.json())
            IPC.shared.send("TextBoxInfo", readTextBox(focus).json())
            let ctx = readAppContext(focus: focus, bundleId: app.bundleId, windowTitle: app.windowTitle, useAx: useAx)
            IPC.shared.send("AppContextUpdate", ctx.json())
        }
    }

    private func startWorkspaceObserver() {
        if workspaceObserver != nil { return }
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: nil
        ) { [weak self] _ in
            self?.axQueue.async {
                IPC.shared.send("AppInfoUpdate", readAppInfo(focus: currentFocus()).json())
            }
        }
    }

    private func focusStored() {
        guard let app = storedApp, !app.isTerminated else { return }
        let ael = axAppElement(app.processIdentifier)
        AXUIElementSetAttributeValue(ael, "AXFrontmost" as CFString, kCFBooleanTrue)
        app.activate()
        sleepMs(80)
        if let el = storedElement {
            AXUIElementSetAttributeValue(el, "AXFocused" as CFString, kCFBooleanTrue)
        }
    }
}
