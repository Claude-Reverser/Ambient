import AVFoundation
import Foundation
import ImageIO

enum WallpaperFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case video = "Video"
    case image = "Images"
    case gif = "GIF"
    case web = "Web"
    case scene = "Scenes"
    var id: String { rawValue }
    func accepts(_ item: Wallpaper) -> Bool {
        switch self {
        case .scene: return item.kind == .scene
        case .all: return true
        case .video: return item.kind == .video
        case .image: return item.kind == .image
        case .gif: return item.url.pathExtension.lowercased() == "gif"
        case .web: return item.kind == .web && item.url.pathExtension.lowercased() != "gif"
        }
    }
}
struct MediaDetails {
    var dimensions = ""
    var size = ""
    var format = ""
    static func read(_ item: Wallpaper) async -> MediaDetails {
        var value = MediaDetails()
        value.format = item.url.pathExtension.uppercased()
        if let bytes = try? item.url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
            value.size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        }
        if item.kind == .scene {
            if let description = try? SceneDescription(package: ScenePackage(url: item.url)) {
                value.dimensions = "\(description.width) × \(description.height) · Metal"
            }
        } else if item.kind == .video {
            if let tracks = try? await AVURLAsset(url: item.url).loadTracks(withMediaType: .video),
                let track = tracks.first,
                let size = try? await track.load(.naturalSize),
                let transform = try? await track.load(.preferredTransform),
                let fps = try? await track.load(.nominalFrameRate)
            {
                let bounds = CGRect(origin: .zero, size: size).applying(transform)
                value.dimensions =
                    "\(Int(abs(bounds.width))) × \(Int(abs(bounds.height))) · \(Int(fps.rounded())) fps"
            }
        } else if item.kind == .image || item.url.pathExtension.lowercased() == "gif",
            let source = CGImageSourceCreateWithURL(
                item.url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
            let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let w = props[kCGImagePropertyPixelWidth] as? Int,
            let h = props[kCGImagePropertyPixelHeight] as? Int
        {
            value.dimensions = "\(w) × \(h)"
        }
        return value
    }
}
