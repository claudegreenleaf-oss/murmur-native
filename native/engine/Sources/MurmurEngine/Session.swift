import Foundation

/// One WebSocket dictation session (shared/protocol/ENGINE.md, "Session framing").
actor DictationSession {
    private static let sampleRate = 16_000
    private static let blockSamples = 640                    // 40 ms
    private static let minSegmentSeconds = 8.0
    private static let pauseBlocks = 13                      // >= 520 ms of quiet

    private let out: WSOutput
    private var ini = InitInfo()
    private var ctx = ContextInfo()
    private var gotInit = false

    private var samples: [Float] = []
    private var leftoverByte: UInt8?
    private var blockDb: [Float] = []
    private var segStart = 0
    private var segTexts: [Int: String] = [:]
    private var segCount = 0
    private var chain: Task<Void, Never>?

    private var committed = false
    private var cancelled = false
    private var done = false
    private var heartbeat: Task<Void, Never>?

    init(out: WSOutput) { self.out = out }

    // MARK: Inbound

    func handleText(_ s: String) async {
        guard !done, let j = parseJSON(Data(s.utf8)) else { return }
        switch j.str("type") {
        case "init":
            ini = InitInfo(json: j.obj("init"))
            ctx = ContextInfo(json: j.obj("context"))
            gotInit = true
            startHeartbeat()
        case "context":
            ctx = ContextInfo(json: j.obj("context"))
        case "commit":
            if !gotInit { startHeartbeat() }
            commit()
        case "cancel":
            cancel()
        default:
            break
        }
    }

    func handleAudio(_ data: Data) {
        guard !done, !committed else { return }
        var bytes = [UInt8](data)
        if let b = leftoverByte { bytes.insert(b, at: 0); leftoverByte = nil }
        if bytes.count % 2 == 1 { leftoverByte = bytes.removeLast() }
        samples.reserveCapacity(samples.count + bytes.count / 2)
        var i = 0
        while i + 1 < bytes.count {
            let v = Int16(bitPattern: UInt16(bytes[i]) | (UInt16(bytes[i + 1]) << 8))
            samples.append(Float(v) / 32768.0)
            i += 2
        }
        updateBlocks()
        maybeCutSegment()
    }

    func connectionClosed() {
        if !done { cancel() }
    }

    // MARK: Level tracking and segmentation

    private func updateBlocks() {
        let bs = Self.blockSamples
        while (blockDb.count + 1) * bs <= samples.count {
            let start = blockDb.count * bs
            var sum: Float = 0
            for k in start..<(start + bs) { sum += samples[k] * samples[k] }
            blockDb.append(Level.dbFromRms((sum / Float(bs)).squareRoot()))
        }
    }

    private var speechThresholdDb: Float {
        let peak = blockDb.max() ?? -100
        return min(max(peak - 28, -60), -38)
    }

    private func maybeCutSegment() {
        let processed = blockDb.count * Self.blockSamples
        guard Double(processed - segStart) >= Self.minSegmentSeconds * Double(Self.sampleRate) else { return }
        guard blockDb.count >= Self.pauseBlocks else { return }
        let thr = speechThresholdDb
        let tail = blockDb.suffix(Self.pauseBlocks)
        guard tail.allSatisfy({ $0 < thr }) else { return }
        launchSegment(from: segStart, to: processed)
        segStart = processed
    }

    private func launchSegment(from a: Int, to b: Int) {
        guard b > a else { return }
        let slice = Array(samples[a..<b])
        let index = segCount
        segCount += 1
        let lang = ini.primaryLanguage
        let prev = chain
        chain = Task { [weak self] in
            await prev?.value
            guard let self = self else { return }
            let text = await engine.asr.transcribe(slice, language: lang)
            await self.segmentDone(index, text)
        }
    }

    private func segmentDone(_ index: Int, _ text: String) {
        segTexts[index] = text
        guard !done, !cancelled else { return }
        if !committed { sendState(raw: rawSoFar(), formatted: "", transcriberDone: false, formatterDone: false) }
    }

    private func rawSoFar() -> String {
        var parts: [String] = []
        var i = 0
        while let t = segTexts[i] {
            if !t.isEmpty { parts.append(t) }
            i += 1
        }
        return parts.joined(separator: " ")
    }

    // MARK: Outbound

    private func startHeartbeat() {
        guard heartbeat == nil else { return }
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                guard let self = self else { return }
                if await self.beat() == false { return }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func beat() -> Bool {
        if done { return false }
        out.sendText(encodeJSONString([
            "type": "heartbeat",
            "audio_received_seconds": finiteDouble(Double(samples.count) / Double(Self.sampleRate)),
            "commit_ack": committed,
        ] as JSON))
        return true
    }

    private func levels() -> (volume: Double, snr: Double) {
        guard !blockDb.isEmpty else { return (-100, 0) }
        let sorted = blockDb.sorted()
        let hi = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
        let lo = sorted[Int(Double(sorted.count) * 0.10)]
        return (Double(hi), Double(max(0, hi - lo)))
    }

    private func sendState(raw: String, formatted: String, transcriberDone: Bool, formatterDone: Bool) {
        let lv = levels()
        let langs = ini.languages.isEmpty ? ["en"] : ini.languages
        let state: JSON = [
            "raw_text": ["content": raw, "languages": langs] as JSON,
            "formatted_text": ["content": formatted, "languages": langs] as JSON,
            "progress": ["transcriber_finished": transcriberDone, "formatter_finished": formatterDone] as JSON,
            "audio_volume_db": finiteDouble(lv.volume),
            "audio_snr_db": finiteDouble(lv.snr),
        ]
        out.sendText(encodeJSONString(["type": "state", "state": state] as JSON))
    }

    private func sendError(_ code: String, _ message: String) {
        out.sendText(encodeJSONString(["type": "error", "code": code, "message": message] as JSON))
        finishSession()
    }

    private func finishSession() {
        done = true
        heartbeat?.cancel()
        out.close()
    }

    // MARK: Commit / cancel

    private func cancel() {
        cancelled = true
        chain?.cancel()
        done = true
        heartbeat?.cancel()
        out.close()
    }

    private func commit() {
        guard !committed else { return }
        committed = true
        // Flush the tail on its own task so `cancel` stays deliverable.
        Task { await self.finalize() }
    }

    private func finalize() async {
        let t0 = Date()
        updateBlocks()
        let processedEnd = samples.count
        let thr = speechThresholdDb
        let tailBlocks = blockDb.suffix(max(0, (processedEnd - segStart) / Self.blockSamples))
        let tailHasSpeech = tailBlocks.contains(where: { $0 >= thr })
        let anySpeech = (blockDb.max() ?? -100) >= -52
        if processedEnd - segStart > 0 && (tailHasSpeech || segCount == 0) && anySpeech {
            launchSegment(from: segStart, to: processedEnd)
            segStart = processedEnd
        }
        let tail = chain
        await tail?.value
        if cancelled || done { return }
        let transcribeMs = Int(Date().timeIntervalSince(t0) * 1000)
        let raw = rawSoFar()
        sendState(raw: raw, formatted: "", transcriberDone: true, formatterDone: false)

        let audioSeconds = Double(samples.count) / Double(Self.sampleRate)
        var result: JSON
        if ini.mode == "command" {
            do {
                let text = try await engine.formatter.runCommand(
                    instruction: raw, selected: ctx.selected, ctx: ctx)
                result = buildResult(
                    status: "formatted", plaintext: text, html: PostProcess.toHTML(text), raw: raw, reason: "",
                    startsProper: false, transcribeMs: transcribeMs, formatMs: Int(Date().timeIntervalSince(t0) * 1000) - transcribeMs,
                    t0: t0, audio: audioSeconds, stats: (0, 0), llm: true)
            } catch {
                sendError("llm_unavailable", "Command mode needs Apple Foundation Models")
                return
            }
        } else {
            let o = await engine.formatter.run(raw: raw, ini: ini, ctx: ctx)
            if cancelled || done { return }
            sendState(raw: raw, formatted: o.plaintext, transcriberDone: true, formatterDone: true)
            result = buildResult(
                status: o.status, plaintext: o.plaintext, html: o.html, raw: raw, reason: o.skipReason,
                startsProper: o.startsWithProperNoun, transcribeMs: transcribeMs, formatMs: o.formatMs,
                t0: t0, audio: audioSeconds, stats: (o.deletions, o.substitutions),
                llm: o.status == "formatted" && ini.format != "none")
        }
        out.sendText(encodeJSONString(["type": "result", "result": result] as JSON))
        finishSession()
    }

    private func buildResult(
        status: String, plaintext: String, html: String, raw: String, reason: String, startsProper: Bool,
        transcribeMs: Int, formatMs: Int, t0: Date, audio: Double, stats: (Int, Int), llm: Bool
    ) -> JSON {
        let langs = ini.languages.isEmpty ? ["en"] : ini.languages
        return [
            "status": status,
            "output": [
                "plaintext": plaintext,
                "html": html,
                "languages": langs,
                "starts_with_proper_noun": startsProper,
            ] as JSON,
            "raw_text": raw,
            "format_skip_reason": reason,
            "timings_ms": [
                "transcribe": transcribeMs,
                "format": max(0, formatMs),
                "total_after_commit": Int(Date().timeIntervalSince(t0) * 1000),
            ] as JSON,
            "audio_duration_s": finiteDouble(audio),
            "engine": "local",
            "asr_model": ASREngine.modelName,
            "llm_model": llm ? ("apple-foundation-models" as Any) : (NSNull() as Any),
            "stats": ["word_deletions": stats.0, "word_substitutions": stats.1] as JSON,
        ]
    }
}
