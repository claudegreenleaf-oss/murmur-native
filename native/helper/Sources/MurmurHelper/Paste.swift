import ApplicationServices
import AppKit
import Foundation

private let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
private let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

typealias SavedPasteboard = [[(NSPasteboard.PasteboardType, Data)]]

func savePasteboard(_ pb: NSPasteboard) -> SavedPasteboard {
    (pb.pasteboardItems ?? []).map { item in
        item.types.compactMap { t in item.data(forType: t).map { (t, $0) } }
    }
}

func restorePasteboard(_ pb: NSPasteboard, _ saved: SavedPasteboard) {
    pb.clearContents()
    let items = saved.compactMap { entries -> NSPasteboardItem? in
        if entries.isEmpty { return nil }
        let it = NSPasteboardItem()
        for (t, d) in entries { it.setData(d, forType: t) }
        return it
    }
    if !items.isEmpty { _ = pb.writeObjects(items) }
}

final class PasteManager {
    static let shared = PasteManager()

    private let queue = DispatchQueue(label: "murmur.helper.paste")
    private let cancelFlag = Locked(false)
    private let busy = Locked(0)

    func cancel() { cancelFlag.set(true) }

    func paste(_ p: JSON) {
        busy.mutate { $0 += 1 }
        queue.async { [self] in
            cancelFlag.set(false)
            run(p)
            busy.mutate { $0 -= 1 }
        }
    }

    private func blocked(_ pasteId: String, _ reason: String, _ t0: Double) {
        IPC.shared.send("PasteBlocked", ["reason": reason])
        IPC.shared.send("PasteOutcome", [
            "pasteId": pasteId, "success": false, "reason": reason, "timeElapsedMs": Int(monoMs() - t0),
        ])
    }

    private func run(_ p: JSON) {
        let t0 = monoMs()
        let pasteId = p["pasteId"] as? String ?? UUID().uuidString
        let text = p["text"] as? String ?? ""
        let html = p["htmlText"] as? String
        let chunks = (p["chunks"] as? [String]) ?? []
        let pressEnter = (p["pressEnterAfter"] as? Bool) ?? false
        let pieces = chunks.isEmpty ? [text] : chunks
        let fullText = pieces.joined()

        if !AXIsProcessTrusted() { return blocked(pasteId, "no_accessibility", t0) }
        if !CGPreflightPostEventAccess() { return blocked(pasteId, "no_post_event", t0) }
        if SecureInputMonitor.current().blocked { return blocked(pasteId, "secure_input", t0) }
        if fullText.isEmpty {
            IPC.shared.send("PasteOutcome", ["pasteId": pasteId, "success": true, "timeElapsedMs": 0])
            return
        }

        EditObserver.shared.end(reason: "new_dictation")

        let focus = currentFocus()
        let before = readTextBox(focus)

        // Held modifiers would turn Cmd+V into something else.
        let deadline = monoMs() + 400
        let modMask: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
        while monoMs() < deadline, !CGEventSource.flagsState(.hidSystemState).intersection(modMask).isEmpty {
            sleepMs(20)
        }

        let pb = NSPasteboard.general
        let saved = savePasteboard(pb)
        var ourChange = pb.changeCount

        func write(_ s: String, html: String?) {
            pb.clearContents()
            var types: [NSPasteboard.PasteboardType] = [.string]
            if html != nil { types.append(.html) }
            types.append(contentsOf: [concealedType, transientType])
            _ = pb.declareTypes(types, owner: nil)
            pb.setString(s, forType: .string)
            if let h = html { pb.setString(h, forType: .html) }
            pb.setData(Data(), forType: concealedType)
            pb.setData(Data(), forType: transientType)
            ourChange = pb.changeCount
        }

        for (i, piece) in pieces.enumerated() {
            if cancelFlag.get() { break }
            write(piece, html: pieces.count == 1 ? html : nil)
            Synth.command("v", fallback: 0x09)
            if i < pieces.count - 1 { sleepMs(150) }
        }
        let tPaste = monoMs()
        if cancelFlag.get() {
            restorePasteboard(pb, saved)
            IPC.shared.send("PasteOutcome", [
                "pasteId": pasteId, "success": false, "reason": "cancelled", "timeElapsedMs": Int(monoMs() - t0),
            ])
            return
        }

        IPC.shared.send("PasteOutcome", ["pasteId": pasteId, "success": true, "timeElapsedMs": Int(tPaste - t0)])

        // Restore the clipboard after 500 ms, verify by re-reading the field, then optionally press Return.
        var restored = false
        var enterSent = !pressEnter
        var verdict: String?
        var verifiedBox: TextBox?
        var verdictAt = 0.0
        let needle = fullText.trimmingCharacters(in: .whitespacesAndNewlines)

        func restoreNow() {
            if !restored {
                restored = true
                if pb.changeCount == ourChange { restorePasteboard(pb, saved) }
            }
        }

        while monoMs() - tPaste < 1800 {
            sleepMs(60)
            let el = monoMs() - tPaste
            if verdict == nil {
                let cur = readTextBox(currentFocus())
                if !cur.couldNot, !before.couldNot || !cur.contents.isEmpty {
                    if cur.contents != before.contents {
                        if cur.before.hasSuffix(fullText) || (!needle.isEmpty && cur.before.hasSuffix(needle)) {
                            verdict = "verified"
                        } else if cur.contents == before.before + fullText + before.after
                                    || (!needle.isEmpty && cur.contents.contains(needle)) {
                            verdict = "verified_before_after"
                        }
                        if verdict != nil {
                            verifiedBox = cur
                            verdictAt = monoMs()
                        }
                    }
                }
            }
            if !restored && el >= 500 { restoreNow() }
            if !enterSent && ((verdict != nil && el >= 120) || el >= 450) {
                Synth.post(keycode: 36)
                enterSent = true
            }
            if restored && enterSent && (verdict != nil || el >= 1000) { break }
        }
        restoreNow()
        if !enterSent { Synth.post(keycode: 36) }

        let finalVerdict = verdict ?? ((before.couldNot || !AXIsProcessTrusted()) ? "skipped" : "not_found")
        let tv = verdict != nil ? verdictAt - tPaste : monoMs() - tPaste
        IPC.shared.send("DictatedTextVerification", [
            "pasteId": pasteId, "verdict": finalVerdict, "timeToVerificationMs": Int(tv),
        ])

        if verdict != nil, let box = verifiedBox, let f = focus ?? currentFocus(), !pressEnter {
            EditObserver.shared.begin(pasteId: pasteId, pastedText: fullText, needle: needle, focus: f, before: before, after: box)
        }
    }

    /// Cmd+C fallback used when the Accessibility selection is empty; restores the clipboard.
    func selectedTextViaCopy() -> JSON {
        let focus = currentFocus()
        var tb = readTextBox(focus)
        if tb.selected.isEmpty, AXIsProcessTrusted(), CGPreflightPostEventAccess() {
            let pb = NSPasteboard.general
            let saved = savePasteboard(pb)
            pb.clearContents()
            let marker = pb.changeCount
            Synth.command("c", fallback: 0x08)
            var waited = 0
            while pb.changeCount == marker, waited < 300 {
                sleepMs(20)
                waited += 20
            }
            if pb.changeCount != marker, let s = pb.string(forType: .string), !s.isEmpty {
                tb.selected = s
                if tb.contents.isEmpty { tb.contents = s }
            }
            restorePasteboard(pb, saved)
        }
        return [
            "beforeText": tb.before, "afterText": tb.after,
            "contents": truncatedJSONString(tb.contents, 20000), "selectedText": truncatedJSONString(tb.selected, 20000),
        ]
    }
}

// MARK: post-paste edit observation

final class EditObserver {
    static let shared = EditObserver()

    private let queue = DispatchQueue(label: "murmur.helper.editobserver")
    private var timer: DispatchSourceTimer?
    private var pasteId = ""
    private var pastedText = ""
    private var element: AXUIElement?
    private var pid: pid_t = 0
    private var prefixAnchor = ""
    private var suffixAnchor = ""
    private var expectedOffset = 0
    private var latest = ""
    private var started = 0.0
    private var active = false

    func begin(pasteId: String, pastedText: String, needle: String, focus: FocusRef, before: TextBox, after: TextBox) {
        queue.async { [self] in
            endLocked(reason: "new_dictation")
            let contents = after.contents as NSString
            let target = pastedText as NSString
            let expected = (before.before as NSString).length
            var best: NSRange?
            var search = NSRange(location: 0, length: contents.length)
            while search.length > 0 {
                let r = contents.range(of: target as String, options: [], range: search)
                if r.location == NSNotFound { break }
                if best == nil || abs(r.location - expected) < abs(best!.location - expected) { best = r }
                search = NSRange(location: r.location + 1, length: contents.length - r.location - 1)
            }
            if best == nil, !needle.isEmpty {
                let r = contents.range(of: needle)
                if r.location != NSNotFound { best = r }
            }
            guard let region = best else { return }
            self.pasteId = pasteId
            self.pastedText = pastedText
            element = focus.element
            pid = focus.pid
            let pre = contents.substring(to: region.location)
            let post = contents.substring(from: region.location + region.length)
            prefixAnchor = String(pre.suffix(30))
            suffixAnchor = String(post.prefix(30))
            expectedOffset = region.location
            latest = contents.substring(with: region)
            started = monoMs()
            active = true
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + 0.3, repeating: 0.3)
            t.setEventHandler { [weak self] in self?.tick() }
            t.resume()
            timer = t
        }
    }

    func end(reason: String) {
        queue.async { [self] in endLocked(reason: reason) }
    }

    private func endLocked(reason: String) {
        guard active else { return }
        active = false
        timer?.cancel()
        timer = nil
        IPC.shared.send("UpdateEditedText", [
            "pasteId": pasteId,
            "pastedText": pastedText,
            "editedText": latest,
            "editDistanceToDictated": editDistance(pastedText, latest),
            "contentObservationEndReason": reason,
        ])
        element = nil
    }

    private func extract(_ contents: String) -> String? {
        let ns = contents as NSString
        var start = 0
        if !prefixAnchor.isEmpty {
            var best: NSRange?
            var search = NSRange(location: 0, length: ns.length)
            while search.length > 0 {
                let r = ns.range(of: prefixAnchor, options: [], range: search)
                if r.location == NSNotFound { break }
                if best == nil || abs(r.location + r.length - expectedOffset) < abs(best!.location + best!.length - expectedOffset) {
                    best = r
                }
                search = NSRange(location: r.location + 1, length: ns.length - r.location - 1)
            }
            guard let b = best else { return nil }
            start = b.location + b.length
        }
        if suffixAnchor.isEmpty { return ns.substring(from: start) }
        let r = ns.range(of: suffixAnchor, options: [], range: NSRange(location: start, length: ns.length - start))
        if r.location == NSNotFound { return nil }
        return ns.substring(with: NSRange(location: start, length: r.location - start))
    }

    private func tick() {
        guard active, let el = element else { return }
        if monoMs() - started > 60_000 { return endLocked(reason: "timeout") }
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != pid {
            return endLocked(reason: "app_change")
        }
        if let f = currentFocus(), !CFEqual(f.element, el) { return endLocked(reason: "focus_change") }
        let tb = readTextBox(FocusRef(element: el, pid: pid))
        if tb.couldNot { return }
        guard let region = extract(tb.contents) else { return endLocked(reason: "anchor_mismatch") }
        if region.isEmpty && !pastedText.isEmpty {
            latest = ""
            return endLocked(reason: "transcript_region_removed")
        }
        latest = region
    }
}
