import Foundation

enum Reply {
    case ack
    case data(String, JSON)
    case error(String, String)
}

/// `|`-framed JSON transport: requests arrive on stdin, everything we send goes to fd 3.
final class IPC {
    static let shared = IPC()

    typealias Handler = (String, Any, @escaping (Reply) -> Void) -> Void

    var handler: Handler?

    private let writeQueue = DispatchQueue(label: "murmur.helper.ipc.write")
    private let dispatchQueue = DispatchQueue(label: "murmur.helper.ipc.dispatch")
    private var pending: [String: (JSON) -> Void] = [:]
    private let pendingLock = NSLock()
    private let outFD: Int32
    private let flat = ProcessInfo.processInfo.environment["MURMUR_HELPER_FLAT"] == "1"
    private let maxChars = 100_000

    private init() {
        if fcntl(3, F_GETFD) != -1 {
            outFD = 3
        } else {
            outFD = -1
            hlog("fd 3 is not open; outbound messages will be dropped")
        }
    }

    // MARK: framing

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "+", with: "+1").replacingOccurrences(of: "|", with: "+2")
    }

    static func unescape(_ bytes: [UInt8]) -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(bytes.count)
        var i = 0
        while i < bytes.count {
            let b = bytes[i]
            if b == 0x2B, i + 1 < bytes.count {
                let n = bytes[i + 1]
                if n == 0x31 {
                    out.append(0x2B)
                } else if n == 0x32 {
                    out.append(0x7C)
                } else {
                    out.append(n)
                }
                i += 2
            } else {
                out.append(b)
                i += 1
            }
        }
        return out
    }

    private func writeAll(_ data: Data) {
        guard outFD >= 0 else { return }
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var off = 0
            while off < data.count {
                let n = write(outFD, base + off, data.count - off)
                if n < 0 {
                    if errno == EINTR { continue }
                    if errno == EAGAIN {
                        var p = pollfd(fd: outFD, events: Int16(POLLOUT), revents: 0)
                        _ = poll(&p, 1, 1000)
                        continue
                    }
                    hlog("write to fd 3 failed errno=\(errno)")
                    return
                }
                off += n
            }
        }
    }

    private func wrap(_ v: JSON) -> JSON {
        flat ? v : ["payload": v]
    }

    private func emit(_ obj: JSON, tooLongFallback: (() -> JSON)? = nil) {
        guard JSONSerialization.isValidJSONObject(obj),
              let data = try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes]),
              let str = String(data: data, encoding: .utf8)
        else {
            hlog("dropping unserialisable message")
            return
        }
        let escaped = IPC.escape(str)
        if escaped.count + 1 > maxChars {
            hlog("IPC message is too long (\(escaped.count) chars)")
            if let fb = tooLongFallback { emit(fb()) }
            return
        }
        let frame = Data((escaped + "|").utf8)
        writeQueue.async { self.writeAll(frame) }
    }

    // MARK: sending

    /// Helper-originated request (the app answers with ACK).
    func send(_ name: String, _ value: JSON, completion: ((JSON) -> Void)? = nil) {
        let uuid = UUID().uuidString.lowercased()
        if let c = completion {
            pendingLock.lock()
            pending[uuid] = c
            pendingLock.unlock()
        }
        let body: JSON = ["uuid": uuid, name: wrap(value)]
        emit(["HelperAPIRequest": body])
    }

    func sendResponse(uuid: String, reply: Reply) {
        var body: JSON = ["uuid": uuid]
        switch reply {
        case .ack:
            body["ACK"] = true
        case .data(let name, let v):
            body[name] = wrap(v)
        case .error(let desc, let type):
            body["HelperAPIError"] = ["payload": ["description": desc, "type": type]]
        }
        emit(["HelperAPIResponse": body], tooLongFallback: {
            ["HelperAPIResponse": ["uuid": uuid, "HelperAPIError": ["payload": ["description": "IPC message is too long", "type": "MESSAGE_TOO_LONG"]]] as JSON]
        })
    }

    // MARK: receiving

    func startReading() {
        let t = Thread { [self] in
            var buffer = [UInt8]()
            var chunk = [UInt8](repeating: 0, count: 65536)
            while true {
                let n = read(0, &chunk, chunk.count)
                if n < 0 {
                    if errno == EINTR { continue }
                    break
                }
                if n == 0 { break }
                buffer.append(contentsOf: chunk[0..<n])
                while let idx = buffer.firstIndex(of: 0x7C) {
                    let frame = Array(buffer[0..<idx])
                    buffer.removeSubrange(0...idx)
                    if !frame.isEmpty { process(frame) }
                }
            }
            hlog("stdin closed, terminating")
            exit(0)
        }
        t.name = "murmur.helper.stdin"
        t.qualityOfService = .userInitiated
        t.start()
    }

    private func process(_ rawFrame: [UInt8]) {
        let bytes = IPC.unescape(rawFrame)
        guard let any = try? JSONSerialization.jsonObject(with: Data(bytes)), let obj = any as? JSON else {
            hlog("unparseable frame (\(bytes.count) bytes)")
            return
        }
        if let req = obj["HelperAPIRequest"] as? JSON {
            let uuid = req["uuid"] as? String ?? ""
            let ignored: Set<String> = ["uuid", "sentryTrace", "sentryBaggage"]
            guard let name = req.keys.first(where: { !ignored.contains($0) }) else {
                sendResponse(uuid: uuid, reply: .error("Empty request", "NO_HANDLER_REGISTERED"))
                return
            }
            let value = req[name] ?? true
            dispatchQueue.async { [self] in
                guard let h = handler else {
                    sendResponse(uuid: uuid, reply: .error("No handler for \(name)", "NO_HANDLER_REGISTERED"))
                    return
                }
                h(name, value) { reply in
                    self.sendResponse(uuid: uuid, reply: reply)
                }
            }
        } else if let resp = obj["HelperAPIResponse"] as? JSON {
            let uuid = resp["uuid"] as? String ?? ""
            pendingLock.lock()
            let c = pending.removeValue(forKey: uuid)
            pendingLock.unlock()
            c?(resp)
        }
    }
}

/// Unwraps `{payload: {...}}` or a bare object into a dictionary.
func payloadDict(_ v: Any) -> JSON {
    if let d = v as? JSON {
        if let p = d["payload"] as? JSON { return p }
        return d
    }
    return [:]
}
