import AppKit
import ImageIO

struct GIFTimeline {
    let ends: [TimeInterval]
    let duration: TimeInterval
    init(delays: [TimeInterval]) {
        var total: TimeInterval = 0
        ends = delays.map {
            total += max(0.02, $0)
            return total
        }
        duration = total
    }
    func index(at time: TimeInterval) -> Int {
        guard duration > 0 else { return 0 }
        let position = max(0, time).truncatingRemainder(dividingBy: duration)
        var low = 0
        var high = ends.count
        while low < high {
            let mid = (low + high) / 2
            if ends[mid] <= position { low = mid + 1 } else { high = mid }
        }
        return min(low, max(0, ends.count - 1))
    }
}

// Decodes only the frame needed now. No array of decompressed animation frames.
@MainActor final class GIFPlayer {
    let view: NSImageView
    private let source: CGImageSource
    private let timeline: GIFTimeline
    private let maxPixel: Int
    private let minimumInterval: Double
    private var timer: Timer?
    private var start: TimeInterval = 0
    private var lastFrame = -1
    init(url: URL, size: CGSize, maxPixel: Int, fps: Int32) throws {
        guard
            let source = CGImageSourceCreateWithURL(
                url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { throw ImportFailure.message("Could not read this GIF.") }
        self.source = source
        let count = CGImageSourceGetCount(source)
        guard count > 0, count <= 20000 else {
            throw ImportFailure.message(
                "This GIF has no frames or exceeds 20,000 frames. Convert it to MP4 for efficient playback."
            )
        }
        let delays = (0..<count).map { index -> Double in
            let properties =
                CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            return (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
                ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double) ?? 0.1
        }
        timeline = GIFTimeline(delays: delays)
        self.maxPixel = maxPixel
        minimumInterval = 1 / Double(fps)
        view = NSImageView(frame: NSRect(origin: .zero, size: size))
        view.imageScaling = .scaleProportionallyUpOrDown
    }
    func play() {
        start = ProcessInfo.processInfo.systemUptime
        tick()
    }
    private func tick() {
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        let index = timeline.index(at: elapsed)
        if index != lastFrame {
            autoreleasepool {
                if let cg = CGImageSourceCreateThumbnailAtIndex(
                    source, index,
                    [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                        kCGImageSourceShouldCacheImmediately: true,
                        kCGImageSourceShouldCache: false,
                    ] as CFDictionary)
                {
                    view.image = NSImage(cgImage: cg, size: .zero)
                }
            }
            lastFrame = index
        }
        guard timeline.ends.count > 1 else { return }
        let untilNext =
            timeline.ends[index] - elapsed.truncatingRemainder(dividingBy: timeline.duration)
        timer = Timer.scheduledTimer(
            withTimeInterval: max(minimumInterval, untilNext), repeats: false
        ) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        timer?.tolerance = 0.003
    }
    func setVisible(_ visible: Bool) {
        timer?.invalidate()
        timer = nil
        if visible { tick() }
    }
    func stop() {
        timer?.invalidate()
        timer = nil
        view.image = nil
    }
    deinit { timer?.invalidate() }
}
