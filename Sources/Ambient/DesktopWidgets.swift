import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct DesktopWidgetSettings: Codable, Equatable {
    var clock = false
    var stats = false
    var scale = 1.0
    var x = 0.5
    var y = 0.18
    var allDisplays = false
}

@MainActor final class DesktopWidgets: NSObject, ObservableObject {
    @Published var settings: DesktopWidgetSettings {
        didSet {
            persist()
            rebuild()
        }
    }
    @Published private(set) var placements: [String: WidgetPlacement]
    @Published private(set) var editing = false
    @Published private(set) var custom: CustomWidgetPackage
    @Published var error: String?
    let readings = SystemReadings()
    private let defaults: UserDefaults
    private var positions: [String: WidgetPosition]
    private(set) var windows: [NSWindow] = []
    private var customHosts: [CustomWidgetHost] = []
    private struct WindowRecord {
        let kind: WidgetKind
        let key: String
        let area: NSRect
        let window: NSWindow
        let native: NSHostingView<AnyView>?
        let custom: CustomWidgetHost?
    }
    private var records: [WindowRecord] = []
    private var editPanel: NSPanel?
    private var timer: Timer?
    private var sleeping = false
    private var inactive = false
    var customEnabled: Bool {
        get { enabled(.custom) }
        set { setEnabled(.custom, newValue) }
    }
    var enabledCount: Int { WidgetKind.allCases.filter { enabled($0) }.count }
    func enabled(_ kind: WidgetKind) -> Bool { placements[kind.rawValue]?.enabled ?? false }
    func scale(_ kind: WidgetKind) -> Double { placements[kind.rawValue]?.scale ?? 1 }
    func setEnabled(_ kind: WidgetKind, _ value: Bool) {
        var placement = placements[kind.rawValue] ?? WidgetPlacement()
        placement.enabled = value
        placements[kind.rawValue] = placement
        saveLayout()
        rebuild()
    }
    func setScale(_ kind: WidgetKind, _ value: Double) {
        var placement = placements[kind.rawValue] ?? WidgetPlacement()
        placement.scale = value
        placements[kind.rawValue] = placement
        saveLayout()
        resize(kind)
    }
    private func resize(_ kind: WidgetKind) {
        for record in records where record.kind == kind {
            let wanted = kind.size(customHeight: custom.height)
            let scale = min(
                max(0.6, min(2.5, self.scale(kind))), record.area.width / wanted.width,
                record.area.height / wanted.height)
            let size = NSSize(width: wanted.width * scale, height: wanted.height * scale)
            let position = positions[record.key] ?? .initial(kind)
            let frame = position.frame(size: size, area: record.area)
            record.native?.rootView = AnyView(
                SingleWidgetFace(readings: readings, kind: kind, scale: scale).frame(
                    width: size.width, height: size.height))
            record.custom?.view.pageZoom = scale
            record.window.setFrame(frame, display: false)
        }
    }
    func resetLayout() {
        positions = [:]
        for kind in WidgetKind.allCases { placements[kind.rawValue]?.scale = 1 }
        saveLayout()
        rebuild()
    }
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let old =
            defaults.data(forKey: "desktopWidgets").flatMap {
                try? JSONDecoder().decode(DesktopWidgetSettings.self, from: $0)
            } ?? DesktopWidgetSettings()
        settings = old
        let migrated: [String: WidgetPlacement] = Dictionary(
            uniqueKeysWithValues: WidgetKind.allCases.map { kind in
                let enabled: Bool
                switch kind {
                case .clock, .date: enabled = old.clock
                case .cpu, .memory: enabled = old.stats
                case .network:
                    enabled = old.stats && (defaults.object(forKey: "widgetGraph") as? Bool ?? true)
                case .custom: enabled = defaults.bool(forKey: "customWidgetEnabled")
                }
                return (kind.rawValue, WidgetPlacement(enabled: enabled, scale: 1))
            })
        placements =
            defaults.data(forKey: "independentWidgets").flatMap {
                try? JSONDecoder().decode([String: WidgetPlacement].self, from: $0)
            } ?? migrated
        positions =
            defaults.data(forKey: "widgetPositions").flatMap {
                try? JSONDecoder().decode([String: WidgetPosition].self, from: $0)
            } ?? [:]
        custom =
            defaults.data(forKey: "customWidgetPackage").flatMap {
                try? JSONDecoder().decode(CustomWidgetPackage.self, from: $0).validated()
            } ?? .starter
        super.init()
        saveLayout()
        NotificationCenter.default.addObserver(
            self, selector: #selector(rebuild),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(
            self, selector: #selector(sleep), name: NSWorkspace.screensDidSleepNotification,
            object: nil)
        center.addObserver(
            self, selector: #selector(wake), name: NSWorkspace.screensDidWakeNotification,
            object: nil)
        center.addObserver(
            self, selector: #selector(resign), name: NSWorkspace.sessionDidResignActiveNotification,
            object: nil)
        center.addObserver(
            self, selector: #selector(activate),
            name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        rebuild()
    }
    deinit {
        timer?.invalidate()
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }
    private func persist() {
        if let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: "desktopWidgets")
        }
    }
    private func saveLayout() {
        if let data = try? JSONEncoder().encode(placements) {
            defaults.set(data, forKey: "independentWidgets")
        }
        if let data = try? JSONEncoder().encode(positions) {
            defaults.set(data, forKey: "widgetPositions")
        }
    }
    func setEditing(_ value: Bool) {
        editing = value
        if value {
            for window in NSApp.windows
            where window.canBecomeMain && window.level == .normal && !window.isMiniaturized {
                window.miniaturize(nil)
            }
        }
        rebuild()
    }
    @objc private func sleep() {
        sleeping = true
        editing = false
        rebuild()
    }
    @objc private func wake() {
        sleeping = false
        rebuild()
    }
    @objc private func resign() {
        inactive = true
        editing = false
        rebuild()
    }
    @objc private func activate() {
        inactive = false
        rebuild()
    }
    @objc private func rebuild() {
        timer?.invalidate()
        timer = nil
        editPanel?.close()
        editPanel = nil
        for host in customHosts { host.stop() }
        customHosts.removeAll()
        for window in windows {
            window.contentView = nil
            window.close()
        }
        windows.removeAll()
        records.removeAll()
        readings.resetBaseline()
        guard !sleeping, !inactive else { return }
        let screens = settings.allDisplays ? NSScreen.screens : Array(NSScreen.screens.prefix(1))
        for screen in screens {
            let area = screen.visibleFrame
            let display =
                (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
                .stringValue ?? "main"
            for kind in WidgetKind.allCases where enabled(kind) {
                let wanted = kind.size(customHeight: custom.height)
                let scale = min(
                    max(0.6, min(2.5, self.scale(kind))), area.width / wanted.width,
                    area.height / wanted.height)
                let size = NSSize(width: wanted.width * scale, height: wanted.height * scale)
                let key = kind.rawValue + "@" + display
                let position = positions[key] ?? .initial(kind)
                let frame = position.frame(size: size, area: area)
                let window = makeWindow(frame)
                window.title = kind.title
                window.identifier = NSUserInterfaceItemIdentifier("widget-" + key)
                let container = NSView(frame: NSRect(origin: .zero, size: size))
                let content: NSView
                var native: NSHostingView<AnyView>?
                var customHost: CustomWidgetHost?
                if kind == .custom {
                    let host = CustomWidgetHost(package: custom, size: size, scale: scale)
                    host.error = { [weak self] in self?.error = $0 }
                    customHosts.append(host)
                    customHost = host
                    content = host.view
                } else {
                    let host = NSHostingView(
                        rootView: AnyView(
                            SingleWidgetFace(readings: readings, kind: kind, scale: scale).frame(
                                width: size.width, height: size.height)))
                    host.sizingOptions = []
                    native = host
                    content = host
                }
                content.frame = container.bounds
                content.autoresizingMask = [.width, .height]
                container.addSubview(content)
                if editing {
                    let drag = WidgetDragSurface(frame: container.bounds)
                    drag.dragBounds = area
                    drag.autoresizingMask = [.width, .height]
                    drag.setAccessibilityLabel("Drag " + kind.title)
                    drag.didDrag = { [weak self, weak window] moved in
                        guard let self, let window else { return }
                        let position = WidgetPosition.from(frame: moved, area: area)
                        self.positions[key] = position
                        self.saveLayout()
                        window.setFrame(
                            position.frame(size: window.frame.size, area: area), display: true)
                    }
                    container.addSubview(drag)
                }
                window.contentView = container
                window.orderFrontRegardless()
                windows.append(window)
                records.append(
                    WindowRecord(
                        kind: kind, key: key, area: area, window: window, native: native,
                        custom: customHost))
            }
        }
        if editing { showEditPanel() }
        guard enabledCount > 0 else { return }
        refresh()
        let stats = enabled(.cpu) || enabled(.memory) || enabled(.network) || customEnabled
        let interval: TimeInterval = stats ? 0.5 : 60
        let firstFire =
            stats
            ? Date().addingTimeInterval(0.5)
            : Date(timeIntervalSince1970: (floor(Date().timeIntervalSince1970 / 60) + 1) * 60)
        let timer = Timer(fire: firstFire, interval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer.tolerance = stats ? 0.025 : 1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
    private func makeWindow(_ frame: NSRect) -> NSWindow {
        let window = DesktopWindow(
            contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.level = NSWindow.Level(
            rawValue: editing
                ? Int(CGWindowLevelForKey(.desktopIconWindow)) + 1
                : Int(CGWindowLevelForKey(.desktopWindow)) + 2)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = !editing
        window.isReleasedWhenClosed = false
        return window
    }
    private func showEditPanel() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let area = screen.visibleFrame
        let panel = NSPanel(
            contentRect: NSRect(x: area.midX - 235, y: area.maxY - 82, width: 470, height: 62),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(
            rootView: HStack(spacing: 16) {
                Image(systemName: "hand.draw").foregroundStyle(AmbientTheme.lavender)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Edit desktop widgets").font(.headline)
                    Text("Drag each widget. Positions save automatically.").font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button("Done") { [weak self] in self?.setEditing(false) }.buttonStyle(
                    VioletButtonStyle())
            }.padding(14).frame(width: 470, height: 62).background(
                AmbientTheme.surface, in: RoundedRectangle(cornerRadius: 16)
            ).preferredColorScheme(.dark))
        panel.orderFrontRegardless()
        editPanel = panel
    }
    private func refresh() {
        readings.refresh(
            stats: enabled(.cpu) || enabled(.memory) || enabled(.network) || customEnabled)
        for host in customHosts { host.update(readings) }
    }
    func applyCustom(_ package: CustomWidgetPackage) {
        do {
            custom = try package.validated()
            defaults.set(try JSONEncoder().encode(custom), forKey: "customWidgetPackage")
            error = nil
            rebuild()
        } catch { self.error = error.localizedDescription }
    }
    func importCustom() -> CustomWidgetPackage? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 300_000 else {
                throw ImportFailure.message("Widget packages must be under 300 KB.")
            }
            return try JSONDecoder().decode(CustomWidgetPackage.self, from: Data(contentsOf: url))
                .validated()
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }
    func exportCustom(_ draft: CustomWidgetPackage) {
        do {
            let package = try draft.validated()
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.json]
            panel.nameFieldStringValue = "Ambient-widget.json"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(package).write(to: url, options: .atomic)
        } catch { self.error = error.localizedDescription }
    }
}
