import AppKit
import CoreAudio
import Foundation

/// Pauses now-playing media (MediaRemote through the perl trampoline) and/or mutes the
/// default output while a dictation is active, and restores only what we changed.
final class MediaManager {
    static let shared = MediaManager()

    private let queue = DispatchQueue(label: "murmur.helper.media")
    private var pausedByUs = false
    private var mutedDevice: AudioDeviceID?
    private var usedMuteProperty = false
    private var savedVolumes: [(UInt32, Float32)] = []

    // MARK: perl trampoline

    private var adapterDir: URL? {
        var candidates: [URL] = []
        if let env = ProcessInfo.processInfo.environment["MURMUR_MEDIAREMOTE_DIR"] {
            candidates.append(URL(fileURLWithPath: env))
        }
        if let r = Bundle.main.resourceURL { candidates.append(r.appendingPathComponent("MediaRemoteAdapter")) }
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        candidates.append(exe)
        candidates.append(exe.appendingPathComponent("../Resources/MediaRemoteAdapter").standardizedFileURL)
        return candidates.first {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("run.pl").path)
                && FileManager.default.fileExists(atPath: $0.appendingPathComponent("libMediaRemoteAdapter.dylib").path)
        }
    }

    private func runPerl(_ command: String, timeout: TimeInterval = 2.5) -> String? {
        guard let dir = adapterDir else {
            hlog("[Media Transport] Perl script not found")
            return nil
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = [dir.appendingPathComponent("run.pl").path, dir.appendingPathComponent("libMediaRemoteAdapter.dylib").path, command]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        let readDone = DispatchSemaphore(value: 0)
        var outData = Data()
        p.terminationHandler = { _ in done.signal() }
        do { try p.run() } catch {
            hlog("[Media Transport] perl launch failed: \(error)")
            return nil
        }
        // Drain stdout concurrently: the now-playing JSON can carry large artwork.
        DispatchQueue.global(qos: .utility).async {
            outData = out.fileHandleForReading.readDataToEndOfFile()
            readDone.signal()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            return nil
        }
        _ = readDone.wait(timeout: .now() + 1)
        return String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func isPlaying() -> Bool {
        guard let line = runPerl("get"), !line.isEmpty, line != "NIL" else { return false }
        let last = line.split(separator: "\n").last.map(String.init) ?? line
        guard let d = last.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: d) as? JSON else { return false }
        if let b = obj["isPlaying"] as? Bool { return b }
        if let n = obj["isPlaying"] as? NSNumber { return n.boolValue }
        return false
    }

    // MARK: lifecycle

    func dictationStart(_ prefs: Prefs) {
        queue.async { [self] in
            if prefs.shouldPauseAudio {
                let playing = isPlaying()
                if playing {
                    _ = runPerl("pause")
                    pausedByUs = true
                }
                IPC.shared.send("IsMediaPlayingUpdate", ["isMediaPlaying": playing])
            }
            if prefs.shouldMuteAudio {
                // Let the app's start sound finish before muting.
                sleepMs(250)
                if Shared.dictationActive.get() { muteOutput() }
            }
        }
    }

    func dictationStop() {
        queue.async { [self] in
            if pausedByUs {
                _ = runPerl("play")
                pausedByUs = false
            }
            unmuteOutput()
        }
    }

    // MARK: CoreAudio

    private func defaultOutput() -> AudioDeviceID? {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let st = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return st == noErr && id != kAudioObjectUnknown ? id : nil
    }

    private func addr(_ selector: AudioObjectPropertySelector, _ element: UInt32) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput, mElement: element)
    }

    private func settable(_ dev: AudioDeviceID, _ selector: AudioObjectPropertySelector, _ element: UInt32) -> Bool {
        var a = addr(selector, element)
        guard AudioObjectHasProperty(dev, &a) else { return false }
        var s = DarwinBoolean(false)
        return AudioObjectIsPropertySettable(dev, &a, &s) == noErr && s.boolValue
    }

    private func getU32(_ dev: AudioDeviceID, _ selector: AudioObjectPropertySelector, _ element: UInt32) -> UInt32? {
        var a = addr(selector, element)
        var v: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(dev, &a, 0, nil, &size, &v) == noErr ? v : nil
    }

    private func setU32(_ dev: AudioDeviceID, _ selector: AudioObjectPropertySelector, _ element: UInt32, _ value: UInt32) -> Bool {
        var a = addr(selector, element)
        var v = value
        return AudioObjectSetPropertyData(dev, &a, 0, nil, UInt32(MemoryLayout<UInt32>.size), &v) == noErr
    }

    private func getF32(_ dev: AudioDeviceID, _ element: UInt32) -> Float32? {
        var a = addr(kAudioDevicePropertyVolumeScalar, element)
        var v: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectGetPropertyData(dev, &a, 0, nil, &size, &v) == noErr ? v : nil
    }

    private func setF32(_ dev: AudioDeviceID, _ element: UInt32, _ value: Float32) -> Bool {
        var a = addr(kAudioDevicePropertyVolumeScalar, element)
        var v = value
        return AudioObjectSetPropertyData(dev, &a, 0, nil, UInt32(MemoryLayout<Float32>.size), &v) == noErr
    }

    private func muteOutput() {
        guard mutedDevice == nil, let dev = defaultOutput() else { return }
        let main = kAudioObjectPropertyElementMain
        if settable(dev, kAudioDevicePropertyMute, main) {
            if getU32(dev, kAudioDevicePropertyMute, main) == 1 { return } // already muted by the user
            if setU32(dev, kAudioDevicePropertyMute, main, 1) {
                mutedDevice = dev
                usedMuteProperty = true
                hlog("[Volume Manager] muted output device \(dev)")
            }
            return
        }
        var saved: [(UInt32, Float32)] = []
        for el in [main, 1, 2] as [UInt32] where settable(dev, kAudioDevicePropertyVolumeScalar, el) {
            if let v = getF32(dev, el) { saved.append((el, v)) }
            if el == main { break }
        }
        guard !saved.isEmpty, saved.contains(where: { $0.1 > 0 }) else { return }
        for (el, _) in saved { _ = setF32(dev, el, 0) }
        savedVolumes = saved
        mutedDevice = dev
        usedMuteProperty = false
        hlog("[Volume Manager] zeroed volume on output device \(dev)")
    }

    private func unmuteOutput() {
        guard let dev = mutedDevice else { return }
        if usedMuteProperty {
            _ = setU32(dev, kAudioDevicePropertyMute, kAudioObjectPropertyElementMain, 0)
        } else {
            for (el, v) in savedVolumes { _ = setF32(dev, el, v) }
        }
        savedVolumes = []
        mutedDevice = nil
    }
}
