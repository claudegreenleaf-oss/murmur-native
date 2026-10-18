import Foundation
import IOKit.ps

enum PowerSource {
    /// True when the Mac is currently running on its battery.
    static var onBattery: Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue() else { return false }
        return (type as String) == "Battery Power"
    }
}

/// Fires a handler once the model it guards has been idle long enough: 3 minutes on battery, 15 on AC.
/// The power source is read when the timer fires, so unplugging mid-wait shortens the wait.
final class IdleUnloader: @unchecked Sendable {
    static let batteryIdle: TimeInterval = 180
    static let acIdle: TimeInterval = 900

    private let lock = NSLock()
    private var lastUsed = Date()
    private var timer: Task<Void, Never>?

    /// Marks the model as just used and makes sure a timer is running. `handler` unloads and returns
    /// false when the model is busy (the timer then retries shortly).
    func touch(_ handler: @escaping @Sendable () async -> Bool) {
        lock.lock(); defer { lock.unlock() }
        lastUsed = Date()
        if timer != nil { return }
        timer = Task { [weak self] in
            while let self = self, !Task.isCancelled {
                let remaining = self.remaining()
                if remaining > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(max(remaining, 1) * 1_000_000_000))
                    continue
                }
                if await handler() { self.finish(); return }
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    private func remaining() -> TimeInterval {
        lock.lock(); defer { lock.unlock() }
        let limit = PowerSource.onBattery ? Self.batteryIdle : Self.acIdle
        return limit - Date().timeIntervalSince(lastUsed)
    }

    private func finish() { lock.lock(); timer = nil; lock.unlock() }
}
