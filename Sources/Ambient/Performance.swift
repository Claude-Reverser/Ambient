import CoreGraphics
import Foundation

enum QualityProfile: String, CaseIterable, Identifiable, Codable {
    case eco, balanced, original
    var id: String { rawValue }
    var title: String {
        switch self {
        case .eco: return "Eco"
        case .balanced: return "Balanced"
        case .original: return "Original"
        }
    }
    var maxDimension: Int {
        switch self {
        case .eco: return 1280
        case .balanced: return 2560
        case .original: return 8192
        }
    }
    var fps: Int32 {
        switch self {
        case .eco: return 24
        case .balanced: return 30
        case .original: return 60
        }
    }
    var detail: String {
        switch self {
        case .eco: return "Up to 720p-class · 24 fps"
        case .balanced: return "Up to 1440p-class · 30 fps"
        case .original: return "Source video quality and frame rate"
        }
    }
    func targetSize(_ source: CGSize) -> CGSize {
        let scale = min(1, CGFloat(maxDimension) / max(source.width, source.height))
        return CGSize(
            width: max(2, floor(source.width * scale / 2) * 2),
            height: max(2, floor(source.height * scale / 2) * 2))
    }
}
enum PauseReason: String {
    case manual = "Paused by you"
    case sleep = "Display asleep"
    case session = "Session inactive"
    case battery = "On battery"
    case lowPower = "Low Power Mode"
    case thermal = "Cooling down"
    case memory = "Paused · critical memory pressure"
}
struct PlaybackConditions {
    var manual = false
    var sleeping = false
    var inactive = false
    var onBattery = false
    var lowPower = false
    var hot = false
    var memoryPressure = false
    func reason(conserve: Bool, pauseOnBattery: Bool) -> PauseReason? {
        if manual { return .manual }
        if sleeping { return .sleep }
        if inactive { return .session }
        if memoryPressure { return .memory }
        if conserve && hot { return .thermal }
        if conserve && lowPower { return .lowPower }
        if pauseOnBattery && onBattery { return .battery }
        return nil
    }
}
