import AVFoundation
import AppKit
import AudioToolbox
import CoreAudio
import Foundation

// MARK: TCC (audio capture permission)

enum TCC {
    /// 0 = authorized, 1 = denied, 2 = not determined; nil if the private symbol is unavailable.
    static func audioCapturePreflight() -> Int? {
        guard let h = dlopen("/System/Library/PrivateFrameworks/TCC.framework/TCC", RTLD_NOW),
              let sym = dlsym(h, "TCCAccessPreflight") else { return nil }
        typealias Fn = @convention(c) (CFString, CFDictionary?) -> Int32
        let fn = unsafeBitCast(sym, to: Fn.self)
        return Int(fn("kTCCServiceAudioCapture" as CFString, nil))
    }
}

enum SystemAudio {
    static func status() -> JSON {
        guard #available(macOS 14.4, *) else {
            return ["authorized": false, "determined": false, "supported": false]
        }
        let p = TCC.audioCapturePreflight()
        return ["authorized": p == 0, "determined": p != nil && p != 2, "supported": true]
    }
}

// MARK: process objects

@available(macOS 14.4, *)
enum AudioProcs {
    struct Proc {
        let object: AudioObjectID
        let pid: pid_t
        let bundleId: String
        let input: Bool
        let output: Bool
    }

    static func addr(_ s: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: s, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    static func u32(_ obj: AudioObjectID, _ s: AudioObjectPropertySelector) -> UInt32? {
        var a = addr(s)
        var v: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &v) == noErr ? v : nil
    }

    static func string(_ obj: AudioObjectID, _ s: AudioObjectPropertySelector) -> String? {
        var a = addr(s)
        var cf: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let st = withUnsafeMutablePointer(to: &cf) { AudioObjectGetPropertyData(obj, &a, 0, nil, &size, $0) }
        return st == noErr ? (cf as String?) : nil
    }

    static func list() -> [Proc] {
        var a = addr(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        let sys = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(sys, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(sys, &a, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { obj in
            guard let pid = u32(obj, kAudioProcessPropertyPID) else { return nil }
            return Proc(
                object: obj,
                pid: pid_t(bitPattern: pid),
                bundleId: string(obj, kAudioProcessPropertyBundleID) ?? "",
                input: (u32(obj, kAudioProcessPropertyIsRunningInput) ?? 0) != 0,
                output: (u32(obj, kAudioProcessPropertyIsRunningOutput) ?? 0) != 0
            )
        }
    }
}

// MARK: system audio tap

@available(macOS 14.4, *)
final class SystemAudioTap {
    static let shared = SystemAudioTap()

    private let queue = DispatchQueue(label: "murmur.helper.sysaudio")
    private let ioQueue = DispatchQueue(label: "murmur.helper.sysaudio.io", qos: .userInteractive)

    private var wanted = false
    private var emitChunks = true
    private var probeToken = 0
    private var prefixes: [String] = []
    private var pids: [Int] = []

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var outputListener: AudioObjectPropertyListenerBlock?
    private var watchdog: DispatchSourceTimer?
    private var wakeObserver: NSObjectProtocol?
    private var recovering = false
    private var attempt = 0

    // io-queue state
    private var converter: AVAudioConverter?
    private var inFormat: AVAudioFormat?
    private var outFormat: AVAudioFormat?
    private var sourceRate = 48000.0
    private var pending: [Int16] = []
    private var nextBlockNs: UInt64 = 0
    private var index = 0
    private var allZero = true
    private var startedMs = 0.0
    private var deniedReported = false
    private let lastCallback = Locked(0.0)

    // MARK: public control

    func start(prefixes: [String], pids: [Int], emit: Bool = true, completion: @escaping (String?) -> Void) {
        queue.async { [self] in
            self.prefixes = prefixes
            self.pids = pids
            emitChunks = emit
            wanted = true
            recovering = false
            attempt = 0
            ioQueue.sync {
                index = 0
                pending.removeAll()
            }
            if let err = build() {
                wanted = false
                teardownHardware()
                emitState("error", err)
                completion(err)
                return
            }
            installWatchers()
            emitState("running", nil)
            completion(nil)
        }
    }

    func stop(completion: (() -> Void)? = nil) {
        queue.async { [self] in
            let was = wanted
            wanted = false
            recovering = false
            removeWatchers()
            teardownHardware()
            if was { emitState("stopped", nil) }
            completion?()
        }
    }

    /// Raises the TCC prompt by running a short throwaway tap.
    func triggerPrompt(_ done: @escaping (String) -> Void) {
        queue.async { [self] in
            if wanted { return done("alreadyInFlight") }
            if let p = TCC.audioCapturePreflight(), p != 2 { return done("alreadyDetermined") }
            probeToken += 1
            let token = probeToken
            start(prefixes: [], pids: [], emit: false) { [self] err in
                if err != nil { return done("unavailable") }
                done("triggered")
                queue.asyncAfter(deadline: .now() + 2) { [self] in
                    if token == probeToken && !emitChunks { stop() }
                }
            }
        }
    }

    // MARK: hardware

    private func emitState(_ state: String, _ reason: String?) {
        guard emitChunks else { return }
        var p: JSON = ["state": state]
        if let r = reason { p["reason"] = r }
        IPC.shared.send("SystemAudioCaptureState", p)
    }

    private func build() -> String? {
        teardownHardware()

        var excluded: [AudioObjectID] = []
        let me = getpid()
        for p in AudioProcs.list() {
            if p.pid == me || pids.contains(Int(p.pid)) || prefixes.contains(where: { p.bundleId.hasPrefix($0) }) {
                excluded.append(p.object)
            }
        }

        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
        desc.name = "Murmur System Audio"
        desc.isPrivate = true
        desc.muteBehavior = .unmuted
        var tap = AudioObjectID(kAudioObjectUnknown)
        let ts = AudioHardwareCreateProcessTap(desc, &tap)
        guard ts == kAudioHardwareNoError else { return "tap_create_failed" }
        tapID = tap

        var agg: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Murmur System Audio",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey: desc.uuid.uuidString, kAudioSubTapDriftCompensationKey: true],
            ],
        ]
        if let clock = clockDeviceUID() {
            agg[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: clock, kAudioSubDeviceDriftCompensationKey: 1]]
            agg[kAudioAggregateDeviceMasterSubDeviceKey] = clock
            agg[kAudioAggregateDeviceClockDeviceKey] = clock
        }
        var aggregate = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateAggregateDevice(agg as CFDictionary, &aggregate) == kAudioHardwareNoError else {
            return "aggregate_create_failed"
        }
        aggID = aggregate

        var rate = nominalRate(aggID) ?? tapRate(tapID) ?? 48000
        if rate <= 0 { rate = 48000 }

        ioQueue.sync {
            sourceRate = rate
            let inF = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)
            let outF = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)
            inFormat = inF
            outFormat = outF
            if let i = inF, let o = outF, rate != 16000 {
                converter = AVAudioConverter(from: i, to: o)
            } else {
                converter = nil
            }
            pending.removeAll()
            nextBlockNs = 0
            allZero = true
            startedMs = monoMs()
            deniedReported = false
        }
        lastCallback.set(monoMs())

        var proc: AudioDeviceIOProcID?
        let st = AudioDeviceCreateIOProcIDWithBlock(&proc, aggID, ioQueue) { [weak self] _, inData, _, _, _ in
            self?.handleInput(inData)
        }
        guard st == noErr, let pid = proc else { return "io_start_failed" }
        procID = pid
        guard AudioDeviceStart(aggID, pid) == noErr else { return "io_start_failed" }
        return nil
    }

    private func teardownHardware() {
        if let pid = procID, aggID != kAudioObjectUnknown {
            AudioDeviceStop(aggID, pid)
            AudioDeviceDestroyIOProcID(aggID, pid)
        }
        procID = nil
        if aggID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggID)
            aggID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    private func clockDeviceUID() -> String? {
        var a = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
        )
        var dev = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &dev) == noErr,
              dev != kAudioObjectUnknown else { return nil }
        var ua = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
        )
        var cf: CFString?
        var usize = UInt32(MemoryLayout<CFString?>.size)
        let st = withUnsafeMutablePointer(to: &cf) { AudioObjectGetPropertyData(dev, &ua, 0, nil, &usize, $0) }
        return st == noErr ? (cf as String?) : nil
    }

    private func nominalRate(_ dev: AudioObjectID) -> Double? {
        var a = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
        )
        var r: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        return AudioObjectGetPropertyData(dev, &a, 0, nil, &size, &r) == noErr ? r : nil
    }

    private func tapRate(_ tap: AudioObjectID) -> Double? {
        var a = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
        )
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.stride)
        return AudioObjectGetPropertyData(tap, &a, 0, nil, &size, &asbd) == noErr ? asbd.mSampleRate : nil
    }

    // MARK: recovery

    private func installWatchers() {
        removeWatchers()
        var a = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.recover("default_output_changed")
        }
        outputListener = block
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, queue, block)

        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: 1)
        t.setEventHandler { [weak self] in
            guard let self, self.wanted, !self.recovering else { return }
            if monoMs() - self.lastCallback.get() > 3000 { self.recover("no_callbacks") }
        }
        t.resume()
        watchdog = t

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: nil
        ) { [weak self] _ in
            self?.queue.asyncAfter(deadline: .now() + 1) { self?.recover("wake") }
        }
    }

    private func removeWatchers() {
        if let b = outputListener {
            var a = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, queue, b)
        }
        outputListener = nil
        watchdog?.cancel()
        watchdog = nil
        if let o = wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        wakeObserver = nil
    }

    private func recover(_ reason: String) {
        guard wanted, !recovering else { return }
        recovering = true
        emitState("recovering", reason)
        hlog("system audio recovering: \(reason)")
        retry()
    }

    private func retry() {
        let delays = [1.0, 2.0, 4.0, 8.0]
        let d = delays[min(attempt, delays.count - 1)]
        queue.asyncAfter(deadline: .now() + d) { [self] in
            guard wanted else { return }
            if let err = build() {
                attempt += 1
                if attempt == 1 { emitState("error", err) }
                retry()
            } else {
                attempt = 0
                recovering = false
                emitState("running", nil)
            }
        }
    }

    // MARK: io (runs on ioQueue)

    private func handleInput(_ inData: UnsafePointer<AudioBufferList>) {
        lastCallback.set(monoMs())
        let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
        var mono: [Float] = []
        var channels = 0
        for buf in abl {
            guard let data = buf.mData else { continue }
            let ch = max(Int(buf.mNumberChannels), 1)
            let frames = Int(buf.mDataByteSize) / (MemoryLayout<Float>.size * ch)
            if frames == 0 { continue }
            if mono.isEmpty { mono = [Float](repeating: 0, count: frames) }
            let n = min(frames, mono.count)
            let fp = data.assumingMemoryBound(to: Float.self)
            for k in 0..<ch {
                for i in 0..<n { mono[i] += fp[i * ch + k] }
            }
            channels += ch
        }
        guard channels > 0, !mono.isEmpty else { return }
        if channels > 1 {
            let inv = 1 / Float(channels)
            for i in 0..<mono.count { mono[i] *= inv }
        }
        let nowNs = AudioConvertHostTimeToNanos(mach_absolute_time())
        let out = resample(mono)
        if out.isEmpty { return }
        if pending.isEmpty && nextBlockNs == 0 { nextBlockNs = nowNs }
        for f in out {
            let c = max(-1, min(1, f))
            let s = Int16((c * 32767).rounded())
            if s != 0 { allZero = false }
            pending.append(s)
        }
        if allZero && !deniedReported && monoMs() - startedMs > 3000 {
            if let p = TCC.audioCapturePreflight(), p != 0 {
                deniedReported = true
                if emitChunks { IPC.shared.send("SystemAudioCaptureState", ["state": "denied", "reason": "silent_zeros"]) }
            }
        }
        while pending.count >= 640 {
            let block = Array(pending.prefix(640))
            pending.removeFirst(640)
            let ns = nextBlockNs
            nextBlockNs += 40_000_000
            let i = index
            index += 1
            if !emitChunks { continue }
            var sum = 0.0
            for s in block { sum += Double(s) * Double(s) }
            let rms = (sum / 640).squareRoot() / 32768
            let db = rms > 0 ? max(-120, 20 * log10(rms)) : -120
            let data = block.withUnsafeBufferPointer { Data(buffer: $0) } // little-endian on arm64 and x86
            IPC.shared.send("SystemAudioChunk", [
                "index": i, "pcm": data.base64EncodedString(), "volumeDb": (db * 10).rounded() / 10, "hostTimeNs": Int(ns),
            ])
        }
    }

    private func resample(_ mono: [Float]) -> [Float] {
        guard let conv = converter, let inF = inFormat, let outF = outFormat else { return mono }
        guard let inBuf = AVAudioPCMBuffer(pcmFormat: inF, frameCapacity: AVAudioFrameCount(mono.count)) else { return [] }
        inBuf.frameLength = AVAudioFrameCount(mono.count)
        mono.withUnsafeBufferPointer { src in
            if let dst = inBuf.floatChannelData?[0], let base = src.baseAddress {
                dst.update(from: base, count: mono.count)
            }
        }
        let cap = AVAudioFrameCount(Double(mono.count) * 16000 / sourceRate) + 64
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: outF, frameCapacity: cap) else { return [] }
        var fed = false
        var err: NSError?
        conv.convert(to: outBuf, error: &err) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return inBuf
        }
        if err != nil { return [] }
        guard let ch = outBuf.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: ch, count: Int(outBuf.frameLength)))
    }
}
