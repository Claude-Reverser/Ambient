import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    // Widget state is read by the widget views themselves. Observing DesktopWidgets here made
    // every widget toggle or size change re-render the whole library, including the wallpaper
    // grid and its filtering/sorting.
    @EnvironmentObject var library: Library
    @State private var page = "Overview"
    @State private var search = ""
    @State private var filter: WallpaperFilter = .all
    @State private var favoritesOnly = false
    @State private var sort = "Newest first"
    @State private var showCompatibility = false
    @State private var showQualityHelp = false
    @State private var isDropTarget = false
    private var filtered: [Wallpaper] {
        let list = library.items.filter { item in
            filter.accepts(item) && (!favoritesOnly || library.favorites.contains(item.id))
                && (search.isEmpty || item.title.localizedCaseInsensitiveContains(search))
        }
        if sort == "Name A–Z" {
            return list.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        }
        if sort == "Favorites first" {
            return list.sorted { a, b in
                let af = library.favorites.contains(a.id)
                let bf = library.favorites.contains(b.id)
                return af == bf
                    ? a.title.localizedStandardCompare(b.title) == .orderedAscending : af
            }
        }
        return list.reversed()
    }
    private var selected: Wallpaper? {
        filtered.first { $0.id == library.selected } ?? filtered.first
    }
    var body: some View {
        NavigationSplitView {
            sidebar.navigationSplitViewColumnWidth(min: 230, ideal: 245, max: 270)
        } detail: {
            if page == "Widgets" {
                WidgetStudio()
            } else if page == "Overview" {
                StudioOverview(
                    library: library, showWallpapers: { page = "Wallpapers" },
                    showWidgets: { page = "Widgets" })
            } else {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    if let selected {
                        WallpaperHero(
                            item: selected, isFavorite: library.favorites.contains(selected.id),
                            isActive: library.active?.id == selected.id,
                            preparing: library.preparing,
                            favorite: { library.toggleFavorite(selected) },
                            apply: { library.apply(selected) })
                    } else {
                        emptyState
                    }
                    collectionToolbar
                    ScrollView {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 178, maximum: 270))], spacing: 16
                        ) {
                            ForEach(filtered) { item in
                                WallpaperCard(
                                    item: item, isSelected: selected?.id == item.id,
                                    isActive: library.active?.id == item.id,
                                    isFavorite: library.favorites.contains(item.id),
                                    select: { library.selected = item.id },
                                    apply: { library.apply(item) },
                                    favorite: { library.toggleFavorite(item) }
                                )
                                .contextMenu {
                                    Button("Apply wallpaper") { library.apply(item) }
                                    Button(
                                        library.favorites.contains(item.id)
                                            ? "Remove from Favorites" : "Add to Favorites"
                                    ) { library.toggleFavorite(item) }
                                    Divider()
                                    Button("Show in Finder") {
                                        NSWorkspace.shared.activateFileViewerSelecting([item.url])
                                    }
                                    Button("Remove from library") { library.remove(item) }
                                }
                            }
                        }.padding(.bottom, 4)
                    }
                    footer
                }.padding(26).background(AmbientTheme.background)
                    .overlay { if isDropTarget { dropOverlay } }
                    .onDrop(
                        of: [UTType.fileURL.identifier], isTargeted: $isDropTarget,
                        perform: receiveDrop)
            }
        }
        .toolbarBackground(.hidden, for: .windowToolbar)
        .tint(AmbientTheme.accent)
        .onChange(of: library.favorites) { _, _ in synchronizeSelection() }
        .onChange(of: library.items.map(\.id)) { _, _ in synchronizeSelection() }
        .onChange(of: filter) { _, _ in synchronizeSelection() }
        .onChange(of: favoritesOnly) { _, _ in synchronizeSelection() }
        .onChange(of: search) { _, _ in synchronizeSelection() }
        .onAppear { synchronizeSelection() }
        .alert(
            "Ambient",
            isPresented: Binding(
                get: { library.message != nil }, set: { if !$0 { library.message = nil } })
        ) {
            Button("OK") { library.message = nil }
        } message: {
            Text(library.message ?? "")
        }
        .sheet(isPresented: $showCompatibility) { compatibility }
    }
    private func synchronizeSelection() { library.selected = selected?.id }
    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 5) {
                Eyebrow(text: "YOUR PERSONAL SPACE")
                Text("Your atmosphere").font(.system(size: 29, weight: .semibold, design: .rounded))
                Text("Make your desktop your own.").font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: library.importFiles) {
                Label(library.importing ? "Importing…" : "Add wallpaper", systemImage: "plus")
            }
            .buttonStyle(VioletButtonStyle()).disabled(library.importing)
        }
    }
    private var collectionToolbar: some View {
        VStack(spacing: 13) {
            HStack(spacing: 7) {
                Text(favoritesOnly ? "Favorites" : "Your collection").font(
                    .system(size: 14, weight: .semibold))
                Text("\(filtered.count)").font(.system(size: 10, weight: .medium)).foregroundStyle(
                    AmbientTheme.lavender
                ).padding(.horizontal, 7).padding(.vertical, 3).background(
                    AmbientTheme.accent.opacity(0.12), in: Capsule())
                Spacer()
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search wallpapers", text: $search).textFieldStyle(.plain)
                }.font(.system(size: 11)).padding(8).frame(width: 185).background(
                    AmbientTheme.surface, in: RoundedRectangle(cornerRadius: 8))
                Menu {
                    Picker("Sort wallpapers", selection: $sort) {
                        Text("Newest first").tag("Newest first")
                        Text("Name A–Z").tag("Name A–Z")
                        Text("Favorites first").tag("Favorites first")
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down").frame(width: 25, height: 25)
                }.menuStyle(.borderlessButton).fixedSize().help("Sort wallpapers")
            }
            HStack(spacing: 6) {
                ForEach(WallpaperFilter.allCases) { category in
                    Button {
                        filter = category
                    } label: {
                        Text(category.rawValue).font(.system(size: 10, weight: .medium)).padding(
                            .horizontal, 13
                        ).padding(.vertical, 7)
                            .foregroundStyle(
                                filter == category ? AmbientTheme.lavender : Color.secondary
                            )
                            .background(
                                filter == category
                                    ? AmbientTheme.accent.opacity(0.16) : Color.clear, in: Capsule()
                            )
                            .overlay(
                                Capsule().stroke(
                                    filter == category
                                        ? AmbientTheme.accent.opacity(0.3)
                                        : Color.white.opacity(0.06)))
                    }.buttonStyle(.plain).accessibilityLabel("Filter: \(category.rawValue)")
                }
                Spacer()
            }
        }
    }
    private var sidebar: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    HStack(spacing: 11) {
                        Image(systemName: "sparkles.rectangle.stack.fill").font(.system(size: 23))
                            .foregroundStyle(AmbientTheme.lavender).frame(width: 38, height: 38)
                            .background(
                                AmbientTheme.accent.opacity(0.13),
                                in: RoundedRectangle(cornerRadius: 11))
                        VStack(alignment: .leading, spacing: 3) {
                            Text("ambient").font(
                                .system(size: 22, weight: .semibold, design: .rounded))
                            Text("YOUR WALLPAPER STUDIO").font(.system(size: 7, weight: .medium))
                                .tracking(1.2).foregroundStyle(.secondary)
                        }
                    }.padding(.vertical, 8)
                    VStack(alignment: .leading, spacing: 7) {
                        Eyebrow(text: "STUDIO").padding(.bottom, 3)
                        navigationRow(
                            "Overview", icon: "rectangle.grid.1x2", count: -1,
                            active: page == "Overview"
                        ) { page = "Overview" }
                        navigationRow(
                            "Widgets", icon: "rectangle.3.group", count: Self.liveWidgetCount,
                            active: page == "Widgets"
                        ) { page = "Widgets" }
                        navigationRow(
                            "All wallpapers", icon: "square.grid.2x2", count: library.items.count,
                            active: page == "Wallpapers" && !favoritesOnly
                        ) {
                            page = "Wallpapers"
                            favoritesOnly = false
                        }
                        navigationRow(
                            "Favorites", icon: "heart", count: library.favorites.count,
                            active: page == "Wallpapers" && favoritesOnly
                        ) {
                            page = "Wallpapers"
                            favoritesOnly = true
                        }
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Eyebrow(text: "PICTURE QUALITY")
                            Spacer()
                            Button {
                                showQualityHelp.toggle()
                            } label: {
                                Image(systemName: "info.circle").font(.caption).foregroundStyle(
                                    .secondary)
                            }.buttonStyle(.plain).help("About quality modes").popover(
                                isPresented: $showQualityHelp
                            ) { qualityHelp }
                        }
                        Picker("Picture quality", selection: $library.profile) {
                            ForEach(QualityProfile.allCases) { Text($0.title).tag($0) }
                        }.pickerStyle(.segmented).labelsHidden().controlSize(.small)
                        Label(
                            library.profile == .original
                                ? (selected?.kind == .scene
                                    ? "Full-resolution textures" : "Full quality, untouched")
                                : library.profile.detail,
                            systemImage: library.profile == .original ? "checkmark.shield" : "leaf"
                        )
                        .font(.system(size: 10)).foregroundStyle(AmbientTheme.lavender)
                        if library.profile != .original {
                            Text("Lower resolution / frame rate. Your source file is preserved.")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }.padding(13).background(
                        AmbientTheme.accent.opacity(0.065), in: RoundedRectangle(cornerRadius: 12)
                    ).overlay(
                        RoundedRectangle(cornerRadius: 12).stroke(AmbientTheme.accent.opacity(0.14))
                    )
                    VStack(alignment: .leading, spacing: 13) {
                        Eyebrow(text: "SMART PLAYBACK")
                        if library.active?.kind == .scene || selected?.kind == .scene {
                            Picker("Scene motion", selection: $library.sceneFPS) {
                                Text("24 fps").tag(24)
                                Text("30 fps").tag(30)
                                Text("60 fps").tag(60)
                            }.help(
                                "Changes scene motion only; original video frame rates stay unchanged."
                            )
                        }
                        Toggle("All displays", isOn: $library.allDisplays).help(
                            "Off uses the primary display only. Changes apply immediately.")
                        Toggle("Pause on battery", isOn: $library.pauseOnBattery)
                        Toggle("Power saving", isOn: $library.conserve).help(
                            "Pause in Low Power Mode and under thermal pressure. Sleep and memory pressure always release playback resources."
                        )
                    }.font(.system(size: 11)).toggleStyle(.switch).controlSize(.mini)
                    Spacer(minLength: 12)
                    nowPlaying
                    HStack {
                        Button {
                            showCompatibility = true
                        } label: {
                            Label("Format guide", systemImage: "questionmark.circle")
                        }.buttonStyle(.plain)
                        Spacer()
                        Menu {
                            Button("Clear optimized copies") { library.clearCache() }
                            Text("Original files are preserved")
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }.menuStyle(.borderlessButton).fixedSize().help("Library maintenance")
                    }.font(.system(size: 10)).foregroundStyle(.secondary)
                }.padding(20).frame(minHeight: geometry.size.height, alignment: .top)
            }.background(AmbientTheme.surface.ignoresSafeArea(edges: .top))
        }
    }
    // Placeholder count: the row renders the enabled widget count from its own observing view.
    private static let liveWidgetCount = -2
    private func navigationRow(
        _ title: String, icon: String, count: Int, active: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: icon).frame(width: 16)
                Text(title)
                Spacer()
                if count == Self.liveWidgetCount {
                    EnabledWidgetCount(active: active)
                } else if count >= 0 {
                    Text("\(count)").font(.system(size: 10).monospacedDigit()).foregroundStyle(
                        active ? AmbientTheme.lavender : .secondary)
                }
            }
            .font(.system(size: 11, weight: .medium)).foregroundStyle(
                active ? AmbientTheme.lavender : Color.secondary
            )
            .padding(.horizontal, 11).padding(.vertical, 11).background(
                active ? AmbientTheme.accent.opacity(0.13) : .clear,
                in: RoundedRectangle(cornerRadius: 9))
        }.buttonStyle(.plain)
    }
    private var nowPlaying: some View {
        VStack(alignment: .leading, spacing: 11) {
            Eyebrow(text: library.active == nil ? "READY WHEN YOU ARE" : "ON YOUR DESKTOP")
            if let active = library.active {
                HStack(spacing: 9) {
                    WallpaperPreview(item: active).frame(width: 38, height: 38).clipShape(
                        RoundedRectangle(cornerRadius: 7))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(active.title).font(.system(size: 11, weight: .medium)).lineLimit(1)
                        Text(library.profile.title + " quality").font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            HStack(spacing: 6) {
                Circle().fill(
                    library.status.hasPrefix("Playing") ? AmbientTheme.accent : .secondary
                ).frame(width: 5, height: 5)
                Text(library.status).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
            }
            HStack(spacing: 8) {
                Button {
                    library.manuallyPaused.toggle()
                } label: {
                    Label(
                        library.manuallyPaused ? "Resume" : "Pause",
                        systemImage: library.manuallyPaused ? "play.fill" : "pause.fill"
                    ).font(.system(size: 10, weight: .medium)).frame(maxWidth: .infinity).padding(
                        .vertical, 8
                    ).background(
                        AmbientTheme.accent.opacity(0.16), in: RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(.plain).disabled(library.active == nil)
                Button {
                    library.stop()
                } label: {
                    Image(systemName: "stop.fill").font(.system(size: 9)).padding(10).background(
                        .white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(.plain).help("Stop wallpaper").disabled(library.active == nil)
            }.foregroundStyle(AmbientTheme.lavender)
        }.padding(13).background(.black.opacity(0.16), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(AmbientTheme.border))
    }
    private var footer: some View {
        HStack(spacing: 7) {
            Image(systemName: "arrow.down.doc").foregroundStyle(AmbientTheme.lavender)
            Text("Drop files or project folders to import").foregroundStyle(.secondary)
            Spacer()
            Text("⌘O  Import    ⌘↵  Apply").foregroundStyle(.tertiary)
        }.font(.system(size: 9))
    }
    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: favoritesOnly ? "heart" : "sparkles.rectangle.stack").font(
                .system(size: 43, weight: .ultraLight)
            ).foregroundStyle(AmbientTheme.lavender)
            Text(library.items.isEmpty ? "A new view starts here." : "Nothing here. Yet.").font(
                .system(size: 21, weight: .medium, design: .rounded))
            Text(
                library.items.isEmpty
                    ? "Drop a wallpaper here, or browse your files."
                    : favoritesOnly
                        ? "Tap a wallpaper’s heart to keep it here."
                        : "Try another format or clear your search."
            ).font(.subheadline).foregroundStyle(.secondary)
            if library.items.isEmpty {
                Button("Browse wallpapers", action: library.importFiles).buttonStyle(
                    VioletButtonStyle())
            } else {
                Button("Show all wallpapers") {
                    filter = .all
                    favoritesOnly = false
                    search = ""
                }.buttonStyle(.link)
            }
        }.frame(maxWidth: .infinity).frame(height: 245).background(
            LinearGradient(
                colors: [AmbientTheme.accent.opacity(0.1), AmbientTheme.surface],
                startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 16)
        ).overlay(RoundedRectangle(cornerRadius: 16).stroke(AmbientTheme.border))
    }
    private var dropOverlay: some View {
        ZStack {
            AmbientTheme.background.opacity(0.94)
            VStack(spacing: 15) {
                Image(systemName: "square.and.arrow.down").font(.system(size: 42))
                Text("Drop into your collection").font(.title2.weight(.semibold))
                Text("Videos, GIFs, images & web project folders").foregroundStyle(.secondary)
            }.foregroundStyle(AmbientTheme.lavender)
        }.padding(8).overlay(
            RoundedRectangle(cornerRadius: 15).stroke(
                AmbientTheme.accent, style: StrokeStyle(lineWidth: 2, dash: [8]))
        ).padding(12).allowsHitTesting(false)
    }
    private func receiveDrop(_ providers: [NSItemProvider]) -> Bool {
        Task { @MainActor in
            var urls: [URL] = []
            for provider in providers {
                let url: URL? = await withCheckedContinuation { continuation in
                    provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) {
                        item, _ in
                        if let data = item as? Data {
                            continuation.resume(
                                returning: URL(dataRepresentation: data, relativeTo: nil))
                        } else if let url = item as? URL {
                            continuation.resume(returning: url)
                        } else {
                            continuation.resume(returning: nil)
                        }
                    }
                }
                if let url { urls.append(url) }
            }
            if !urls.isEmpty { library.importURLs(urls) }
        }
        return true
    }
    private var qualityHelp: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text("Your quality. Your choice.").font(.headline)
            Text(
                "Original plays your video unchanged: no re-encoding, reduced resolution, or frame-rate cap. It is the default."
            )
            Text(
                "Balanced limits large videos to a 2560-pixel edge / 30 fps. Eco uses 1280 pixels / 24 fps. Both prepare a reusable HEVC copy and keep your original file."
            ).foregroundStyle(.secondary)
            Text(
                "First video preparation uses extra CPU/GPU. Scenes keep full-resolution textures and default to 30 fps, adjustable under Scene motion. Web frame rates depend on the project."
            ).foregroundStyle(.secondary)
        }.font(.system(size: 11)).padding(20).frame(width: 315)
    }
    private var compatibility: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Bring your own atmosphere", systemImage: "sparkles").font(.title2.bold())
                .foregroundStyle(AmbientTheme.lavender)
            Text(
                "Videos: MP4, MOV, M4V with macOS-playable codecs.\nImages: PNG, JPEG, HEIC, TIFF.\nAnimation: GIF, decoded natively.\nWeb: HTML files and extracted web project folders."
            )
            Text(
                "Wallpaper Engine video/web projects and a limited set of scene.pkg files are supported. The experimental Metal scene renderer handles one full-canvas image and the verified water-flow shader used by Waves. Multi-layer scenes, other shaders, particles, puppet animation, audio reactivity, and Windows applications are not supported yet."
            ).foregroundStyle(.secondary)
            Text(
                "Web wallpapers can access the network and run scripts. Only import web content you trust. Quality modes cannot enforce limits on arbitrary websites."
            ).foregroundStyle(.secondary)
            Button("Got it") { showCompatibility = false }.buttonStyle(VioletButtonStyle()).frame(
                maxWidth: .infinity, alignment: .trailing)
        }.padding(30).frame(width: 520).background(AmbientTheme.surface)
    }
}

private struct EnabledWidgetCount: View {
    @EnvironmentObject var widgets: DesktopWidgets
    let active: Bool
    var body: some View {
        Text("\(widgets.enabledCount)").font(.system(size: 10).monospacedDigit()).foregroundStyle(
            active ? AmbientTheme.lavender : .secondary)
    }
}
