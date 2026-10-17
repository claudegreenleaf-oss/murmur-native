import Foundation

typealias JSON = [String: Any]

extension Dictionary where Key == String, Value == Any {
    func str(_ k: String) -> String { (self[k] as? String) ?? "" }
    func obj(_ k: String) -> JSON? { self[k] as? JSON }
    func strs(_ k: String) -> [String] { ((self[k] as? [Any]) ?? []).compactMap { $0 as? String } }
    func strMap(_ k: String) -> [String: String] {
        var out: [String: String] = [:]
        for (key, v) in (self[k] as? JSON) ?? [:] {
            if let s = v as? String { out[key] = s }
        }
        return out
    }
}

func parseJSON(_ data: Data) -> JSON? {
    (try? JSONSerialization.jsonObject(with: data)) as? JSON
}

func encodeJSON(_ obj: Any) -> Data {
    (try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes]))
        ?? Data("{}".utf8)
}

func encodeJSONString(_ obj: Any) -> String {
    String(data: encodeJSON(obj), encoding: .utf8) ?? "{}"
}

func finiteDouble(_ v: Double) -> Double { v.isFinite ? v : 0 }

func elog(_ s: String) {
    FileHandle.standardError.write(Data(("[MurmurEngine] " + s + "\n").utf8))
}

/// One-shot latch used to race a result against a timeout.
final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    func fire() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if fired { return false }
        fired = true
        return true
    }
}

struct RaceTimeout: Error {}

func race<T: Sendable>(timeout: Double, _ op: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
        let gate = Gate()
        let work = Task {
            do {
                let v = try await op()
                if gate.fire() { cont.resume(returning: v) }
            } catch {
                if gate.fire() { cont.resume(throwing: error) }
            }
        }
        Task {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            if gate.fire() {
                work.cancel()
                cont.resume(throwing: RaceTimeout())
            }
        }
    }
}
