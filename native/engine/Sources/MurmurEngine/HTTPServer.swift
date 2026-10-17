import Foundation
import Network
import CryptoKit

/// Minimal HTTP/1.1 + WebSocket server on loopback. One request per connection (Connection: close),
/// except for the WebSocket upgrade on /v1/dictate.
final class EngineServer: @unchecked Sendable {
    private let port: UInt16
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "murmur.server")

    init(port: UInt16) { self.port = port }

    func start() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host("127.0.0.1"), port: NWEndpoint.Port(rawValue: port)!)
        let l = try NWListener(using: params)
        l.newConnectionHandler = { conn in
            let c = ClientConnection(conn)
            c.start()
        }
        l.stateUpdateHandler = { state in
            switch state {
            case .ready: elog("listening on 127.0.0.1:\(self.port)")
            case .failed(let e):
                elog("listener failed: \(e)")
                exit(2)
            default: break
            }
        }
        l.start(queue: queue)
        listener = l
    }
}

struct HTTPRequest {
    var method = ""
    var path = ""
    var headers: [String: String] = [:]
    var body = Data()
}

/// Output side of a WebSocket, handed to a dictation session.
final class WSOutput: @unchecked Sendable {
    private let conn: ClientConnection
    init(_ c: ClientConnection) { conn = c }
    func sendText(_ s: String) { conn.sendFrame(opcode: 0x1, payload: Data(s.utf8)) }
    func close() { conn.closeWebSocket() }
}

enum WSEvent {
    case text(String)
    case binary(Data)
    case closed
}

final class ClientConnection: @unchecked Sendable {
    private let conn: NWConnection
    private let queue = DispatchQueue(label: "murmur.conn")
    private var buffer = Data()
    private var isWebSocket = false
    private var closed = false
    private var fragmentOpcode: UInt8 = 0
    private var fragmentData = Data()
    private var events: AsyncStream<WSEvent>.Continuation?

    private static let maxHeader = 64 * 1024
    private static let maxBody = 16 * 1024 * 1024

    init(_ c: NWConnection) { conn = c }

    func start() {
        // Strong capture on purpose: nothing else retains this object while the connection lives.
        // teardown() clears the handler to break the cycle.
        conn.stateUpdateHandler = { state in
            switch state {
            case .failed, .cancelled: self.teardown()
            default: break
            }
        }
        conn.start(queue: queue)
        receive()
    }

    private func teardown() {
        queue.async {
            if self.closed { return }
            self.closed = true
            self.events?.yield(.closed)
            self.events?.finish()
            self.conn.stateUpdateHandler = nil
            self.conn.cancel()
        }
    }

    private func receive() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { data, _, isComplete, error in
            if let d = data, !d.isEmpty {
                self.buffer.append(d)
                self.process()
            }
            if error != nil || isComplete {
                self.teardown()
                return
            }
            if !self.closed { self.receive() }
        }
    }

    private func process() {
        if isWebSocket {
            while parseFrame() {}
        } else {
            parseHTTP()
        }
    }

    // MARK: HTTP

    private func parseHTTP() {
        guard let headEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            if buffer.count > Self.maxHeader { respond(status: 431, json: ["error": "headers too large"]) }
            return
        }
        let headData = buffer.subdata(in: buffer.startIndex..<headEnd.lowerBound)
        guard let head = String(data: headData, encoding: .utf8) else {
            respond(status: 400, json: ["error": "bad request"])
            return
        }
        var lines = head.components(separatedBy: "\r\n")
        let first = lines.removeFirst().split(separator: " ")
        guard first.count >= 2 else {
            respond(status: 400, json: ["error": "bad request line"])
            return
        }
        var req = HTTPRequest()
        req.method = String(first[0]).uppercased()
        let rawPath = String(first[1])
        req.path = rawPath.split(separator: "?", maxSplits: 1).first.map(String.init) ?? rawPath
        for l in lines {
            guard let idx = l.firstIndex(of: ":") else { continue }
            let k = l[l.startIndex..<idx].lowercased()
            let v = l[l.index(after: idx)...].trimmingCharacters(in: .whitespaces)
            req.headers[k] = v
        }
        let bodyStart = headEnd.upperBound
        let want = Int(req.headers["content-length"] ?? "0") ?? 0
        if want > Self.maxBody {
            respond(status: 413, json: ["error": "body too large"])
            return
        }
        if buffer.count - bodyStart < want { return }
        req.body = buffer.subdata(in: bodyStart..<(bodyStart + want))
        buffer = buffer.subdata(in: (bodyStart + want)..<buffer.endIndex)
        route(req)
    }

    private func route(_ req: HTTPRequest) {
        let upgrade = (req.headers["upgrade"] ?? "").lowercased()
        if req.path == "/v1/dictate" && upgrade == "websocket" {
            upgradeToWebSocket(req)
            return
        }
        switch (req.method, req.path) {
        case ("GET", "/healthz"):
            Task { self.respond(status: 200, json: await engine.health()) }
        case ("POST", "/v1/format"):
            Task {
                let out = await engine.handleFormat(parseJSON(req.body) ?? [:])
                self.respond(status: 200, json: out)
            }
        case ("POST", "/v1/command"):
            Task {
                let out = await engine.handleCommand(parseJSON(req.body) ?? [:])
                self.respond(status: 200, json: out)
            }
        case ("POST", "/v1/extract_edited_words"):
            Task {
                let out = await engine.handleExtract(parseJSON(req.body) ?? [:])
                self.respond(status: 200, json: out)
            }
        default:
            respond(status: 404, json: ["error": "not found"])
        }
    }

    private func respond(status: Int, json: Any) {
        let body = encodeJSON(json)
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 400: reason = "Bad Request"
        case 404: reason = "Not Found"
        case 413: reason = "Payload Too Large"
        default: reason = "Error"
        }
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        head += "Content-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var out = Data(head.utf8)
        out.append(body)
        conn.send(content: out, completion: .contentProcessed { _ in
            self.teardown()
        })
    }

    // MARK: WebSocket

    private func upgradeToWebSocket(_ req: HTTPRequest) {
        guard let key = req.headers["sec-websocket-key"], !key.isEmpty else {
            respond(status: 400, json: ["error": "missing Sec-WebSocket-Key"])
            return
        }
        let digest = Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))
        let accept = Data(digest).base64EncodedString()
        let head = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n"
        isWebSocket = true
        conn.send(content: Data(head.utf8), completion: .contentProcessed { _ in })

        var cont: AsyncStream<WSEvent>.Continuation!
        let stream = AsyncStream<WSEvent>(bufferingPolicy: .unbounded) { cont = $0 }
        events = cont
        let session = DictationSession(out: WSOutput(self))
        Task {
            // Single consumer keeps audio frames strictly ordered.
            for await ev in stream {
                switch ev {
                case .text(let s): await session.handleText(s)
                case .binary(let d): await session.handleAudio(d)
                case .closed: await session.connectionClosed()
                }
            }
        }
        // Any bytes that followed the handshake already sit in `buffer`.
        while parseFrame() {}
    }

    /// Parses one frame from `buffer`. Returns true if a frame was consumed.
    private func parseFrame() -> Bool {
        let b = [UInt8](buffer.prefix(14))
        if b.count < 2 { return false }
        let fin = (b[0] & 0x80) != 0
        let opcode = b[0] & 0x0F
        let masked = (b[1] & 0x80) != 0
        var len = Int(b[1] & 0x7F)
        var idx = 2
        if len == 126 {
            if b.count < 4 { return false }
            len = (Int(b[2]) << 8) | Int(b[3])
            idx = 4
        } else if len == 127 {
            if b.count < 10 { return false }
            var l: UInt64 = 0
            for i in 2..<10 { l = (l << 8) | UInt64(b[i]) }
            if l > UInt64(Self.maxBody) {
                closeWebSocket()
                return false
            }
            len = Int(l)
            idx = 10
        }
        var maskKey = [UInt8](repeating: 0, count: 4)
        if masked {
            if b.count < idx + 4 { return false }
            maskKey = Array(b[idx..<(idx + 4)])
            idx += 4
        }
        if buffer.count < idx + len { return false }
        let start = buffer.startIndex + idx
        var payload = [UInt8](buffer[start..<(start + len)])
        if masked {
            for i in 0..<payload.count { payload[i] ^= maskKey[i & 3] }
        }
        buffer = buffer.subdata(in: (buffer.startIndex + idx + len)..<buffer.endIndex)
        handleFrame(fin: fin, opcode: opcode, payload: Data(payload))
        return true
    }

    private func handleFrame(fin: Bool, opcode: UInt8, payload: Data) {
        switch opcode {
        case 0x0:  // continuation
            fragmentData.append(payload)
            if fin { deliver(opcode: fragmentOpcode, data: fragmentData); fragmentData = Data() }
        case 0x1, 0x2:
            if fin { deliver(opcode: opcode, data: payload) }
            else { fragmentOpcode = opcode; fragmentData = payload }
        case 0x8:
            closeWebSocket()
        case 0x9:
            sendFrame(opcode: 0xA, payload: payload)
        default:
            break
        }
    }

    private func deliver(opcode: UInt8, data: Data) {
        if opcode == 0x1 {
            events?.yield(.text(String(data: data, encoding: .utf8) ?? ""))
        } else {
            events?.yield(.binary(data))
        }
    }

    func sendFrame(opcode: UInt8, payload: Data) {
        var frame = Data()
        frame.append(0x80 | opcode)
        if payload.count < 126 {
            frame.append(UInt8(payload.count))
        } else if payload.count <= 0xFFFF {
            frame.append(126)
            frame.append(UInt8(payload.count >> 8))
            frame.append(UInt8(payload.count & 0xFF))
        } else {
            frame.append(127)
            for shift in stride(from: 56, through: 0, by: -8) {
                frame.append(UInt8((UInt64(payload.count) >> UInt64(shift)) & 0xFF))
            }
        }
        frame.append(payload)
        queue.async {
            if self.closed { return }
            self.conn.send(content: frame, completion: .contentProcessed { _ in })
        }
    }

    func closeWebSocket() {
        queue.async {
            if self.closed { return }
            let f = Data([0x88, 0x02, 0x03, 0xE8])  // close, 1000
            self.conn.send(content: f, completion: .contentProcessed { _ in
                self.teardown()
            })
        }
    }
}
