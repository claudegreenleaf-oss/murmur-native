import AppKit
import CoreAudio
import Darwin
import Foundation

/// Which apps currently hold the microphone, from Core Audio process objects (macOS 14.4+).
@available(macOS 14.4, *)
final class MicHoldersMonitor {
    static let shared = MicHoldersMonitor()

    private let queue = DispatchQueue(label: "murmur.helper.micholders")
    private var timer: DispatchSourceTimer?
    private var lastKey: String?
    private var seq = 0
    private var wakeObserver: NSObjectProtocol?

    func set(enabled: Bool, cadenceMs: Int?) {
        queue.async { [self] in
            timer?.cancel()
            timer = nil
            if let o = wakeObserver {
                NSWorkspace.shared.notificationCenter.removeObserver(o)
                wakeObserver = nil
            }
            lastKey = nil
            guard enabled else { return }
            let ms = max(250, cadenceMs ?? 1000)
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now(), repeating: .milliseconds(ms))
            t.setEventHandler { [weak self] in self?.tick() }
            t.resume()
            timer = t
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: nil
            ) { [weak self] _ in
                self?.queue.async { self?.lastKey = nil }
            }
        }
    }

    func snapshot() -> JSON {
        let procs = AudioProcs.list()
        let me = getpid()
        func holders(_ pick: (AudioProcs.Proc) -> Bool) -> [JSON] {
            var seen = Set<String>()
            var out: [JSON] = []
            for p in procs where pick(p) && p.pid != me {
                let id = MicHoldersMonitor.identity(pid: p.pid, bundleId: p.bundleId)
                if seen.insert(id.key).inserted {
                    out.append([
                        "name": id.name, "bundleIdOrExePath": id.key, "processId": Int(p.pid), "source": "process_api",
                    ])
                }
            }
            return out
        }
        return [
            "holders": holders { $0.input },
            "outputHolders": holders { $0.output },
            "deviceInUse": MicHoldersMonitor.defaultInputInUse(),
            "detectionMethod": "process_api",
            "observationSeq": seq,
            "listenerActive": false,
            "observedAtMs": Int(Date().timeIntervalSince1970 * 1000),
        ]
    }

    private func tick() {
        var s = snapshot()
        let holders = (s["holders"] as? [JSON]) ?? []
        let key = holders.map { ($0["bundleIdOrExePath"] as? String ?? "") + ":" + String($0["processId"] as? Int ?? 0) }
            .sorted().joined(separator: ",") + "|\(s["deviceInUse"] as? Bool ?? false)"
        if key == lastKey { return }
        lastKey = key
        seq += 1
        s["observationSeq"] = seq
        IPC.shared.send("MicrophoneHoldersChanged", s)
    }

    /// Owning app of a (possibly helper) process: bundle id and display name, else executable path.
    static func identity(pid: pid_t, bundleId: String) -> (key: String, name: String) {
        var buf = [CChar](repeating: 0, count: 4096)
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        if n > 0 {
            let path = String(cString: buf)
            let comps = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            if let i = comps.firstIndex(where: { $0.hasSuffix(".app") }) {
                let appPath = "/" + comps[0...i].joined(separator: "/")
                if let b = Bundle(path: appPath) {
                    let id = b.bundleIdentifier ?? bundleId
                    let name = (b.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                        ?? (b.object(forInfoDictionaryKey: "CFBundleName") as? String)
                        ?? String(comps[i].dropLast(4))
                    return (id.isEmpty ? appPath : id, name)
                }
            }
            return (path, comps.last ?? path)
        }
        if let app = NSRunningApplication(processIdentifier: pid) {
            return (app.bundleIdentifier ?? bundleId, app.localizedName ?? bundleId)
        }
        return (bundleId, bundleId)
    }

    static func defaultInputInUse() -> Bool {
        var a = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
        )
        var dev = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &dev) == noErr,
              dev != kAudioObjectUnknown else { return false }
        var b = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
        )
        var running: UInt32 = 0
        var rsize = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(dev, &b, 0, nil, &rsize, &running) == noErr && running != 0
    }
}
