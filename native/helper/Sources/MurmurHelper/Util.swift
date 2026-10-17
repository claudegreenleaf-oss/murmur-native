import Foundation

typealias JSON = [String: Any]

func hlog(_ s: String) {
    FileHandle.standardError.write(Data(("[helper] " + s + "\n").utf8))
}

final class Locked<T> {
    private var value: T
    private let lock = NSLock()
    init(_ v: T) { value = v }
    func get() -> T {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
    func set(_ v: T) {
        lock.lock()
        value = v
        lock.unlock()
    }
    func mutate<R>(_ f: (inout T) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return f(&value)
    }
}

func monoMs() -> Double {
    Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000
}

func sleepMs(_ ms: Int) {
    if ms > 0 { usleep(UInt32(ms) * 1000) }
}

/// Levenshtein distance over unicode scalars; strips the common prefix and suffix first.
func editDistance(_ a: String, _ b: String) -> Int {
    var x = Array(a.unicodeScalars)
    var y = Array(b.unicodeScalars)
    var p = 0
    while p < x.count && p < y.count && x[p] == y[p] { p += 1 }
    x.removeFirst(p)
    y.removeFirst(p)
    var s = 0
    while s < x.count && s < y.count && x[x.count - 1 - s] == y[y.count - 1 - s] { s += 1 }
    x.removeLast(s)
    y.removeLast(s)
    if x.isEmpty { return y.count }
    if y.isEmpty { return x.count }
    if x.count > 3000 || y.count > 3000 { return max(x.count, y.count) }
    var prev = Array(0...y.count)
    var cur = [Int](repeating: 0, count: y.count + 1)
    for i in 1...x.count {
        cur[0] = i
        for j in 1...y.count {
            let cost = x[i - 1] == y[j - 1] ? 0 : 1
            cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
        }
        swap(&prev, &cur)
    }
    return prev[y.count]
}

func truncatedJSONString(_ s: String, _ max: Int) -> String {
    s.count <= max ? s : String(s.prefix(max))
}

func onMain<T>(_ f: () -> T) -> T {
    Thread.isMainThread ? f() : DispatchQueue.main.sync(execute: f)
}
