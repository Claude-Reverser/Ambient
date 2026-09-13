import AVFoundation
import AppKit
import CryptoKit
import ImageIO

// Serial actor bounds still-image decoding and thumbnail work. Never retain full-size originals.
actor ImageLoader {
    static let shared = ImageLoader()
    private let thumbnails = NSCache<NSString, NSImage>()
    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private func acquire() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }
    private func release() {
        if waiting.isEmpty { busy = false } else { waiting.removeFirst().resume() }
    }
    init() {
        thumbnails.totalCostLimit = 16 * 1024 * 1024
        thumbnails.countLimit = 48
    }
    func clear() { thumbnails.removeAllObjects() }
    func image(_ url: URL, maxPixel: Int) -> NSImage? {
        guard
            let source = CGImageSourceCreateWithURL(
                url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
            let cg = CGImageSourceCreateThumbnailAtIndex(
                source, 0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                    kCGImageSourceShouldCacheImmediately: true,
                ] as CFDictionary)
        else { return nil }
        return NSImage(cgImage: cg, size: .zero)
    }
    func thumbnail(_ item: Wallpaper, maxPixel: Int = 480) async -> NSImage? {
        await acquire()
        defer { release() }
        guard !Task.isCancelled else { return nil }
        let key =
            (item.path + "-\(maxPixel)-"
            + String(
                (try? item.url.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate?.timeIntervalSince1970) ?? 0)) as NSString
        if let cached = thumbnails.object(forKey: key) { return cached }
        let result: NSImage?
        if item.kind == .video {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: item.url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
            if let frame = try? await generator.image(at: .zero) {
                result = NSImage(cgImage: frame.image, size: .zero)
            } else {
                result = nil
            }
        } else if item.kind == .scene
            || item.kind == .web && item.url.pathExtension.lowercased() != "gif"
        {
            let preview = URL(fileURLWithPath: item.root).appendingPathComponent("preview.jpg")
            result = image(preview, maxPixel: maxPixel)
        } else {
            result = image(item.url, maxPixel: maxPixel)
        }
        if let result {
            thumbnails.setObject(
                result, forKey: key, cost: Int(result.size.width * result.size.height * 4))
        }
        return result
    }
}

@MainActor final class VideoOptimizer {
    static let budget: Int64 = 1024 * 1024 * 1024
    let directory: URL
    private var session: AVAssetExportSession?
    init(directory: URL? = nil) {
        self.directory =
            directory
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Ambient/Video-v2")
    }
    func cancel() { session?.cancelExport() }
    func preparedURL(for item: Wallpaper, profile: QualityProfile) async throws -> URL {
        guard item.kind == .video, profile != .original else { return item.url }
        try Task.checkCancellation()
        let asset = AVURLAsset(url: item.url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw ImportFailure.message("No video track was found.")
        }
        let natural = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let rect = CGRect(origin: .zero, size: natural).applying(transform)
        let source = CGSize(width: abs(rect.width), height: abs(rect.height))
        let rate = try await track.load(.nominalFrameRate)
        guard
            max(source.width, source.height) > CGFloat(profile.maxDimension)
                || rate > Float(profile.fps) + 0.1
        else { return item.url }
        let attributes = try item.url.resourceValues(forKeys: [
            .fileSizeKey, .contentModificationDateKey,
        ])
        let identity =
            "v2|\(item.path)|\(attributes.fileSize ?? 0)|\(attributes.contentModificationDate?.timeIntervalSince1970 ?? 0)|\(profile.rawValue)"
        let hash = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }
            .joined()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Recover abandoned temporary exports after a previous process crash.
        for file
            in (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        where file.lastPathComponent.hasSuffix(".partial.mp4") {
            if let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate, Date().timeIntervalSince(modified) > 86400
            {
                try? FileManager.default.removeItem(at: file)
            }
        }
        let output = directory.appendingPathComponent(hash + ".mp4")
        if FileManager.default.fileExists(atPath: output.path) {
            try? FileManager.default.setAttributes(
                [.modificationDate: Date()], ofItemAtPath: output.path)
            return output
        }
        let temporary = directory.appendingPathComponent(UUID().uuidString + ".partial.mp4")
        defer {
            try? FileManager.default.removeItem(at: temporary)
            session = nil
        }
        guard
            let export = AVAssetExportSession(
                asset: asset, presetName: AVAssetExportPresetHEVCHighestQuality)
        else {
            throw ImportFailure.message(
                "Could not prepare an efficient copy. Try Original quality.")
        }
        let target = profile.targetSize(source)
        let composition = AVMutableVideoComposition()
        composition.renderSize = target
        composition.frameDuration = CMTime(
            value: 1, timescale: min(profile.fps, max(1, Int32(rate.rounded(.up)))))
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: try await asset.load(.duration))
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        let adjusted = transform.concatenating(
            CGAffineTransform(translationX: -rect.minX, y: -rect.minY)
        ).concatenating(
            CGAffineTransform(scaleX: target.width / source.width, y: target.height / source.height)
        )
        layer.setTransform(adjusted, at: .zero)
        instruction.layerInstructions = [layer]
        composition.instructions = [instruction]
        export.videoComposition = composition
        export.outputURL = temporary
        export.outputFileType = .mp4
        export.shouldOptimizeForNetworkUse = false
        session = export
        await withTaskCancellationHandler(
            operation: { await export.export() },
            onCancel: { [weak self] in Task { @MainActor in self?.cancel() } })
        try Task.checkCancellation()
        guard export.status == .completed else {
            throw export.error
                ?? ImportFailure.message("Could not optimize this video. Try Original quality.")
        }
        let size = Int64((try temporary.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0)
        guard size <= Self.budget else {
            throw ImportFailure.message(
                "The efficient copy exceeds the 1 GB cache budget. Choose a shorter video or Original quality."
            )
        }
        try trim(to: Self.budget - size)
        try FileManager.default.moveItem(at: temporary, to: output)
        return output
    }
    func trim(to budget: Int64) throws {
        let files =
            (try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])) ?? []
        let entries = files.filter {
            $0.pathExtension == "mp4" && !$0.lastPathComponent.contains(".partial.")
        }.map { url in
            (url, try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]))
        }.sorted {
            ($0.1?.contentModificationDate ?? .distantPast)
                < ($1.1?.contentModificationDate ?? .distantPast)
        }
        var total = entries.reduce(Int64(0)) { $0 + Int64($1.1?.fileSize ?? 0) }
        for (url, value) in entries where total > budget {
            try FileManager.default.removeItem(at: url)
            total -= Int64(value?.fileSize ?? 0)
        }
    }
}
