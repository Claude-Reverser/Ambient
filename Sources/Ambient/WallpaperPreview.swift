import AppKit
import SwiftUI

struct WallpaperPreview: View {
    let item: Wallpaper
    var maxPixel: Int = 480
    var fit = false
    @State private var image: NSImage?
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                LinearGradient(
                    colors: [
                        Color(red: 0.25, green: 0.13, blue: 0.4),
                        Color(red: 0.12, green: 0.1, blue: 0.22), .black,
                    ], startPoint: .topLeading, endPoint: .bottomTrailing)
                if let image {
                    if fit {
                        Image(nsImage: image).resizable().scaledToFit().frame(
                            width: geometry.size.width, height: geometry.size.height)
                    } else {
                        Image(nsImage: image).resizable().scaledToFill().frame(
                            width: geometry.size.width, height: geometry.size.height
                        ).clipped()
                    }
                } else {
                    Image(
                        systemName: item.kind == .video
                            ? "play.rectangle" : item.kind == .web ? "globe" : "photo"
                    ).font(.system(size: 38, weight: .ultraLight)).foregroundStyle(
                        .white.opacity(0.5))
                }
            }
        }
        .task(id: item.path) {
            let loaded = await ImageLoader.shared.thumbnail(item, maxPixel: maxPixel)
            guard !Task.isCancelled else { return }
            image = loaded
        }
        .onDisappear { image = nil }
    }
}
