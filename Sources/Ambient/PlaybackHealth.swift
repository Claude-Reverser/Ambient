import Darwin
import Foundation

struct VideoHealth {
    enum Action: Equatable { case none, resume, rebuild, failed }
    private var lastPosition: Double?
    private var lastItem: ObjectIdentifier?
    private var stationaryChecks = 0
    private var attempts = 0
    private var healthyChecks = 0
    mutating func inspect(position: Double, item: ObjectIdentifier?, failed: Bool) -> Action {
        let progressed =
            position.isFinite
            && (lastPosition == nil || abs(position - lastPosition!) > 0.05 || item != lastItem)
        lastPosition = position
        lastItem = item
        if !failed, progressed {
            stationaryChecks = 0
            healthyChecks += 1
            if healthyChecks >= 15 { attempts = 0 }
            return .none
        }
        healthyChecks = 0
        stationaryChecks += 1
        if !failed, stationaryChecks == 3 { return .resume }
        guard failed || stationaryChecks >= 6 else { return .none }
        stationaryChecks = 0
        lastPosition = nil
        lastItem = nil
        attempts += 1
        return attempts <= 3 ? .rebuild : .failed
    }
}

struct MemoryPressureRecovery {
    private(set) var paused = false
    private var recoveredSince: TimeInterval?
    mutating func critical() {
        paused = true
        recoveredSince = nil
    }
    mutating func check(level: Int32?, now: TimeInterval) -> Bool {
        guard paused else { return false }
        guard let level, level == 1 || level == 2 else {
            recoveredSince = nil
            return false
        }
        if recoveredSince == nil { recoveredSince = now }
        guard now - recoveredSince! >= 20 else { return false }
        paused = false
        recoveredSince = nil
        return true
    }
    static func currentLevel() -> Int32? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("kern.memorystatus_vm_pressure_level", &value, &size, nil, 0) == 0
            ? value : nil
    }
}
