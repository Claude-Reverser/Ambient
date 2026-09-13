import SwiftUI

struct StudioOverview: View {
    @ObservedObject var library: Library
    @ObservedObject var widgets: DesktopWidgets
    let showWallpapers: () -> Void
    let showWidgets: () -> Void
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Eyebrow(text: "YOUR DESKTOP, AT A GLANCE")
                Text("Welcome to your space").font(
                    .system(size: 30, weight: .semibold, design: .rounded))
                HStack(spacing: 14) {
                    summary(
                        "Wallpapers", value: "\(library.items.count)", icon: "photo.stack",
                        action: showWallpapers)
                    summary(
                        "Widgets enabled", value: "\(widgets.enabledCount)",
                        icon: "rectangle.3.group", action: showWidgets)
                    summary(
                        "Picture quality", value: library.profile.title, icon: "sparkles",
                        action: showWallpapers)
                }
                if let active = library.active {
                    WallpaperHero(
                        item: active, isFavorite: library.favorites.contains(active.id),
                        isActive: true, preparing: library.preparing,
                        favorite: { library.toggleFavorite(active) },
                        apply: { library.apply(active) })
                }
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Label("Playback health", systemImage: "heart.text.square").font(.headline)
                        Spacer()
                        Text(library.status).foregroundStyle(AmbientTheme.lavender)
                    }
                    Text(
                        "Automatic stall recovery is active during video playback. Intentional pauses, sleep and critical memory pressure are respected."
                    ).font(.subheadline).foregroundStyle(.secondary)
                    HStack {
                        Button(library.manuallyPaused ? "Resume" : "Pause") {
                            library.manuallyPaused.toggle()
                        }.disabled(library.active == nil)
                        Button("Restart wallpaper") {
                            if let active = library.active { library.apply(active) }
                        }.disabled(library.active == nil)
                        Spacer()
                        Button("Open widget studio", action: showWidgets).buttonStyle(
                            VioletButtonStyle())
                    }
                    Divider()
                    Text("Recent activity").font(.caption.weight(.semibold)).foregroundStyle(
                        .secondary)
                    ForEach(
                        Array(library.playbackEvents.suffix(6).reversed().enumerated()),
                        id: \.offset
                    ) { _, event in
                        Text(event).font(.system(size: 11, design: .monospaced)).foregroundStyle(
                            .secondary
                        ).textSelection(.enabled)
                    }
                }.padding(22).background(
                    AmbientTheme.surface, in: RoundedRectangle(cornerRadius: 16))
            }.padding(26)
        }.background(AmbientTheme.background)
    }
    private func summary(_ label: String, value: String, icon: String, action: @escaping () -> Void)
        -> some View
    {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                Label(label, systemImage: icon).font(.caption).foregroundStyle(
                    AmbientTheme.lavender)
                Text(value).font(.system(size: 25, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            }.padding(20).frame(maxWidth: .infinity, alignment: .leading).background(
                AmbientTheme.surface, in: RoundedRectangle(cornerRadius: 14))
        }.buttonStyle(.plain)
    }
}
