import AVFoundation
import AppKit
import IOKit.ps
import SwiftUI

@MainActor final class Library: NSObject, ObservableObject {
    @Published var items: [Wallpaper] = []
    @Published var selected: UUID? {
        didSet { defaults.set(selected?.uuidString, forKey: "selectedWallpaper") }
    }
    @Published private(set) var favorites: Set<UUID> = []
    @Published var message: String?
    @Published var status = "Ready" { didSet { if oldValue != status { recordPlayback(status) } } }
    @Published private(set) var playbackEvents: [String] = []
    @Published var manuallyPaused = false {
        didSet {
            defaults.set(manuallyPaused, forKey: "manuallyPaused")
            updatePolicy()
        }
    }
    @Published var conserve = true {
        didSet {
            defaults.set(conserve, forKey: "conserve")
            updatePolicy()
        }
    }
    @Published var pauseOnBattery = true {
        didSet {
            defaults.set(pauseOnBattery, forKey: "pauseOnBattery")
            updatePolicy()
        }
    }
    @Published var allDisplays = true {
        didSet {
            defaults.set(allDisplays, forKey: "allDisplays")
            reapply()
        }
    }
    @Published var profile: QualityProfile = .original {
        didSet {
            defaults.set(profile.rawValue, forKey: "profile")
            reapply()
        }
    }
    @Published var sceneFPS = 30 {
        didSet {
            defaults.set(sceneFPS, forKey: "sceneFPS")
            if active?.kind == .scene { reapply() }
        }
    }
    @Published var importing = false
    @Published private(set) var preparing = false
    @Published private(set) var active: Wallpaper?
    @Published private(set) var usingOptimizedVideo = false
    private(set) var renderers: [Renderer] = []
    private var conditions = PlaybackConditions()
    private var preparation: Task<Void, Never>?
    private var generation = UUID()
    private var memoryRecovery: Task<Void, Never>?
    private var pressureRecovery = MemoryPressureRecovery()
    private var pressureSource: DispatchSourceMemoryPressure?
    private var powerSource: CFRunLoopSource?
    private let storage: URL
    private let defaults: UserDefaults
    init(storage: URL? = nil, defaults: UserDefaults = .standard) {
        self.storage =
            storage
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Ambient/library.json")
        self.defaults = defaults
        super.init()
        if let data = try? Data(contentsOf: self.storage),
            let saved = try? JSONDecoder().decode([Wallpaper].self, from: data)
        {
            items = saved
        }
        conserve = defaults.object(forKey: "conserve") as? Bool ?? true
        pauseOnBattery = defaults.object(forKey: "pauseOnBattery") as? Bool ?? true
        allDisplays = defaults.object(forKey: "allDisplays") as? Bool ?? true
        profile =
            QualityProfile(rawValue: defaults.string(forKey: "profile") ?? "original") ?? .original
        let savedSceneFPS = defaults.integer(forKey: "sceneFPS")
        sceneFPS = [24, 30, 60].contains(savedSceneFPS) ? savedSceneFPS : 30
        selected =
            defaults.string(forKey: "selectedWallpaper").flatMap(UUID.init(uuidString:))
            ?? items.first?.id
        favorites = Set(
            (defaults.stringArray(forKey: "favorites") ?? []).compactMap(UUID.init(uuidString:)))
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(
            self, selector: #selector(screenSleep), name: NSWorkspace.screensDidSleepNotification,
            object: nil)
        workspace.addObserver(
            self, selector: #selector(screenWake), name: NSWorkspace.screensDidWakeNotification,
            object: nil)
        workspace.addObserver(
            self, selector: #selector(sessionInactive),
            name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        workspace.addObserver(
            self, selector: #selector(sessionActive),
            name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(updatePolicy), name: .NSProcessInfoPowerStateDidChange,
            object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(updatePolicy),
            name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(displaysChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        let pressure = DispatchSource.makeMemoryPressureSource(
            eventMask: [.normal, .warning, .critical], queue: .main)
        pressure.setEventHandler { [weak self, weak pressure] in
            guard let self, let pressure else { return }
            let event = pressure.data
            if event.contains(.critical) {
                self.pressureRecovery.critical()
                self.conditions.memoryPressure = true
                Task { await ImageLoader.shared.clear() }
                self.updatePolicy()
                self.startMemoryRecovery()
            } else {
                if event.contains(.warning) { Task { await ImageLoader.shared.clear() } }
                if self.conditions.memoryPressure { self.startMemoryRecovery() }
            }
        }
        pressure.activate()
        pressureSource = pressure
        let callback: IOPowerSourceCallbackType = { context in
            guard let context else { return }
            MainActor.assumeIsolated {
                Unmanaged<Library>.fromOpaque(context).takeUnretainedValue().updatePolicy()
            }
        }
        powerSource = IOPSNotificationCreateRunLoopSource(
            callback, Unmanaged.passUnretained(self).toOpaque())?.takeRetainedValue()
        if let powerSource { CFRunLoopAddSource(CFRunLoopGetMain(), powerSource, .commonModes) }
        manuallyPaused = defaults.bool(forKey: "manuallyPaused")
        updatePolicy()
        if storage == nil,
            let id = defaults.string(forKey: "activeWallpaper").flatMap(UUID.init(uuidString:)),
            let item = items.first(where: { $0.id == id })
        {
            apply(item)
        }
    }
    deinit {
        preparation?.cancel()
        pressureSource?.cancel()
        memoryRecovery?.cancel()
        if let powerSource { CFRunLoopSourceInvalidate(powerSource) }
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }
    func recordPlayback(_ event: String) {
        playbackEvents.append(Date().formatted(date: .omitted, time: .standard) + " · " + event)
        if playbackEvents.count > 50 { playbackEvents.removeFirst(playbackEvents.count - 50) }
    }
    private func startMemoryRecovery() {
        guard memoryRecovery == nil else { return }
        memoryRecovery = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                guard let self else { return }
                if self.pressureRecovery.check(
                    level: MemoryPressureRecovery.currentLevel(),
                    now: ProcessInfo.processInfo.systemUptime)
                {
                    self.conditions.memoryPressure = false
                    self.memoryRecovery = nil
                    self.recordPlayback("Memory pressure eased; resuming wallpaper")
                    self.updatePolicy()
                    return
                }
            }
        }
    }
    func importFiles() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Import"
        guard panel.runModal() == .OK else { return }
        importURLs(panel.urls)
    }
    func importURLs(_ urls: [URL]) {
        guard !importing else {
            message = "An import is already in progress. Try again when it finishes."
            return
        }
        importing = true
        Task {
            var errors: [String] = []
            for url in urls {
                do {
                    let item = try WallpaperImporter.resolve(url)
                    if item.kind == .scene { try await SceneLoader.shared.validate(item.url) }
                    if item.kind == .video {
                        guard try await AVURLAsset(url: item.url).load(.isPlayable) else {
                            throw ImportFailure.message(
                                "This codec cannot be played by macOS. Convert it to H.264 or HEVC MP4."
                            )
                        }
                    } else if item.kind == .image,
                        await ImageLoader.shared.image(item.url, maxPixel: 64) == nil
                    {
                        throw ImportFailure.message("The image could not be decoded.")
                    }
                    if let existing = items.first(where: { $0.path == item.path }) {
                        selected = existing.id
                    } else {
                        items.append(item)
                        selected = item.id
                    }
                } catch { errors.append("\(url.lastPathComponent): \(error.localizedDescription)") }
            }
            save()
            importing = false
            if !errors.isEmpty { message = errors.joined(separator: "\n\n") }
        }
    }
    private func save() {
        do {
            try FileManager.default.createDirectory(
                at: storage.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(items).write(to: storage, options: .atomic)
        } catch { message = "Could not save the library: \(error.localizedDescription)" }
    }
    func apply(_ item: Wallpaper) {
        guard FileManager.default.fileExists(atPath: item.path) else {
            message = "This file was moved or deleted. Import it again from its new location."
            return
        }
        stop()
        active = item
        defaults.set(item.id.uuidString, forKey: "activeWallpaper")
        updatePolicy()
    }
    private func prepare(_ item: Wallpaper) {
        let ticket = UUID()
        generation = ticket
        let quality = profile
        preparing = true
        status = "Preparing \(quality.title.lowercased()) playback…"
        preparation = Task { [weak self] in
            do {
                let optimizer = VideoOptimizer()
                let sceneResources =
                    item.kind == .scene
                    ? try await SceneLoader.shared.resources(for: item.url) : nil
                let url = try await optimizer.preparedURL(for: item, profile: quality)
                try Task.checkCancellation()
                guard let self, generation == ticket else { return }
                let screens = allDisplays ? NSScreen.screens : Array(NSScreen.screens.prefix(1))
                usingOptimizedVideo = url != item.url
                renderers = screens.map {
                    Renderer(
                        wallpaper: item, screen: $0, mediaURL: url, profile: quality,
                        initiallyPaused: true, sceneResources: sceneResources,
                        sceneFPS: self.sceneFPS,
                        onEvent: { [weak self] in self?.recordPlayback($0) }
                    ) { [weak self] error in
                        self?.message = error
                        self?.recordPlayback(error)
                        self?.manuallyPaused = true
                    }
                }
                preparation = nil
                preparing = false
                updatePolicy()
            } catch {
                guard let self, generation == ticket, !Task.isCancelled else { return }
                message = error.localizedDescription
                stop()
            }
        }
    }
    func toggleFavorite(_ item: Wallpaper) {
        if favorites.contains(item.id) {
            favorites.remove(item.id)
        } else {
            favorites.insert(item.id)
        }
        defaults.set(favorites.map(\.uuidString), forKey: "favorites")
    }
    private func reapply() { if let active { apply(active) } }
    func remove(_ item: Wallpaper) {
        if active?.id == item.id { stop() }
        items.removeAll { $0.id == item.id }
        favorites.remove(item.id)
        defaults.set(favorites.map(\.uuidString), forKey: "favorites")
        selected = nil
        save()
    }
    func stop(preserveSelection: Bool = false) {
        if !preserveSelection { defaults.removeObject(forKey: "activeWallpaper") }
        generation = UUID()
        preparation?.cancel()
        preparation = nil
        preparing = false
        for renderer in renderers { renderer.stop() }
        renderers.removeAll()
        active = nil
        usingOptimizedVideo = false
        status = "Stopped"
    }
    func clearCache() {
        stop()
        do {
            try VideoOptimizer().trim(to: 0)
            Task { await ImageLoader.shared.clear() }
        } catch { message = error.localizedDescription }
    }
    @objc private func screenSleep() {
        conditions.sleeping = true
        updatePolicy()
    }
    @objc private func screenWake() {
        conditions.sleeping = false
        updatePolicy()
    }
    @objc private func sessionInactive() {
        conditions.inactive = true
        updatePolicy()
    }
    @objc private func sessionActive() {
        conditions.inactive = false
        updatePolicy()
    }
    @objc private func displaysChanged() { reapply() }
    @objc func updatePolicy() {
        conditions.manual = manuallyPaused
        conditions.lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        conditions.hot = [.serious, .critical].contains(ProcessInfo.processInfo.thermalState)
        if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
            let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue()
        {
            conditions.onBattery = (type as String) == kIOPSBatteryPowerValue
        }
        let reason = conditions.reason(conserve: conserve, pauseOnBattery: pauseOnBattery)
        if reason != nil, preparing {
            generation = UUID()
            preparation?.cancel()
            preparation = nil
            preparing = false
        }
        for renderer in renderers { renderer.setPaused(reason != nil) }
        guard let active else {
            status = "Ready"
            return
        }
        if let reason {
            status = reason.rawValue
            return
        }
        if renderers.isEmpty, !preparing {
            prepare(active)
            return
        }
        if !preparing {
            status = "Playing · \(renderers.count) display\(renderers.count == 1 ? "" : "s")"
        }
    }
}
