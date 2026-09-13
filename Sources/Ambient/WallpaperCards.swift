import AppKit
import SwiftUI

extension Wallpaper {
    var displayKind: String {
        kind == .scene
            ? "Scene"
            : url.pathExtension.lowercased() == "gif"
                ? "GIF" : kind == .web ? "Web" : kind == .image ? "Image" : "Video"
    }
    var symbol: String {
        kind == .scene
            ? "cube.transparent"
            : displayKind == "GIF"
                ? "square.stack.3d.up"
                : kind == .video ? "play.rectangle" : kind == .web ? "globe" : "photo"
    }
}
struct WallpaperHero: View {
    let item: Wallpaper
    let isFavorite: Bool
    let isActive: Bool
    let preparing: Bool
    let favorite: () -> Void
    let apply: () -> Void
    @State private var details = MediaDetails()
    @State private var fitPreview = true
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            WallpaperPreview(item: item, maxPixel: 1280, fit: fitPreview)
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.15), location: 0),
                    .init(color: .clear, location: 0.35),
                    .init(color: .black.opacity(0.88), location: 1),
                ], startPoint: .top, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    DetailBadge(
                        text: isActive ? "CURRENT WALLPAPER" : "PREVIEW",
                        icon: isActive ? "checkmark.circle.fill" : "viewfinder")
                    Spacer()
                    Button {
                        fitPreview.toggle()
                    } label: {
                        Image(
                            systemName: fitPreview
                                ? "arrow.up.left.and.arrow.down.right"
                                : "arrow.down.right.and.arrow.up.left"
                        ).font(.system(size: 12)).foregroundStyle(.white).frame(
                            width: 34, height: 34
                        ).background(.black.opacity(0.32), in: Circle()).overlay(
                            Circle().stroke(.white.opacity(0.15)))
                    }.buttonStyle(.plain).help(
                        fitPreview ? "Fill preview area" : "Show entire wallpaper"
                    ).accessibilityLabel("Toggle preview fit")
                    Button(action: favorite) {
                        Image(systemName: isFavorite ? "heart.fill" : "heart").font(
                            .system(size: 14)
                        ).foregroundStyle(isFavorite ? AmbientTheme.lavender : .white).frame(
                            width: 34, height: 34
                        ).background(.black.opacity(0.32), in: Circle()).overlay(
                            Circle().stroke(.white.opacity(0.15)))
                    }.buttonStyle(.plain).help(
                        isFavorite ? "Remove from Favorites" : "Add to Favorites"
                    ).accessibilityLabel("Favorite selected wallpaper")
                }
                Spacer()
                HStack(alignment: .bottom, spacing: 12) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(item.title).font(
                            .system(size: 27, weight: .semibold, design: .rounded)
                        ).lineLimit(1).foregroundStyle(.white)
                        HStack(spacing: 6) {
                            DetailBadge(text: item.displayKind, icon: item.symbol)
                            if !details.dimensions.isEmpty {
                                DetailBadge(
                                    text: details.dimensions,
                                    icon: "arrow.up.left.and.arrow.down.right")
                            }
                            if !details.size.isEmpty {
                                DetailBadge(text: details.size, icon: "doc")
                            }
                        }
                    }
                    Spacer(minLength: 0)
                    Button(action: apply) {
                        Label(preparing ? "Preparing…" : "Set wallpaper", systemImage: "play.fill")
                    }.buttonStyle(VioletButtonStyle()).disabled(preparing)
                }
            }.padding(20)
        }
        .frame(height: 245).clipShape(RoundedRectangle(cornerRadius: 16)).overlay(
            RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.12))
        )
        .task(id: item.path) {
            details = MediaDetails()
            let loaded = await MediaDetails.read(item)
            guard !Task.isCancelled else { return }
            details = loaded
        }
    }
}
struct WallpaperCard: View {
    let item: Wallpaper
    let isSelected: Bool
    let isActive: Bool
    let isFavorite: Bool
    let select: () -> Void
    let apply: () -> Void
    let favorite: () -> Void
    @State private var hovered = false
    private var border: Color {
        isSelected
            ? AmbientTheme.accent.opacity(0.85)
            : hovered ? AmbientTheme.accent.opacity(0.35) : AmbientTheme.border
    }
    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 0) {
                WallpaperPreview(item: item).frame(height: 107).overlay(alignment: .bottomLeading) {
                    Label(item.displayKind, systemImage: item.symbol).font(
                        .system(size: 8, weight: .semibold)
                    ).padding(.horizontal, 7).padding(.vertical, 4).background(
                        .black.opacity(0.6), in: Capsule()
                    ).padding(8)
                }.clipped()
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title).font(.system(size: 11, weight: .medium)).lineLimit(1)
                        Text(isActive ? "Current wallpaper" : item.url.pathExtension.uppercased())
                            .font(.system(size: 9)).foregroundStyle(
                                isActive ? AmbientTheme.lavender : Color.secondary)
                    }
                    Spacer(minLength: 2)
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(
                            AmbientTheme.accent
                        ).font(.system(size: 13))
                    }
                }.padding(11)
            }
            .background(AmbientTheme.surface).clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12).stroke(border, lineWidth: isSelected ? 1.5 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(.plain).simultaneousGesture(TapGesture(count: 2).onEnded { apply() }).onHover
        { hovered = $0 }.help("Single-click to preview. Double-click to set wallpaper.")
            .overlay(alignment: .topTrailing) {
                Button(action: favorite) {
                    Image(systemName: isFavorite ? "heart.fill" : "heart").font(.system(size: 11))
                        .foregroundStyle(isFavorite ? AmbientTheme.lavender : .white.opacity(0.85))
                        .frame(width: 27, height: 27).background(.black.opacity(0.45), in: Circle())
                }
                .buttonStyle(.plain).padding(7).help(
                    isFavorite ? "Remove from Favorites" : "Add to Favorites"
                ).accessibilityLabel("Favorite \(item.title)")
            }
    }
}
