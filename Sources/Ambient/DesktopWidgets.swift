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
    var windows: [NSWindow] { records.map(\.window) }
    // One live window per widget and display. Windows, hosting views and custom web views are
    // kept across toggles, edit mode and resizing; only widgets that appear or disappear are
    // created or closed. Recreating every WKWebView and hosting view on each click was the main
    // source of UI stalls.
    @MainActor private final class WindowRecord {
        let kind: WidgetKind
        let key: String
        var area: NSRect
        let window: NSWindow
        let container: NSView
        let face: WidgetFaceState?
        let custom: CustomWidgetHost?
        var drag: WidgetDragSurface?
        init(
            kind: WidgetKind, key: String, area: NSRect, window: NSWindow, container: NSView,
            face: WidgetFaceState?, custom: CustomWidgetHost?
        ) {
            self.kind = kind
            self.key = key
            self.area = area
            self.window = window
            self.container = container
            self.face = face
            self.custom = custom
        }
    }
    private var records: [WindowRecord] = []
    private var editPanel: NSPanel?
    private var timer: Timer?
    private var timerSamplesStats: Bool?
    private var pendingSave: Task<Void, Never>?
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
        // Sliders call this for every movement; write preferences once the value settles.
        scheduleSave()
        for record in records where record.kind == kind { layout(record) }
    }
    private func layout(_ record: WindowRecord) {
        let wanted = record.kind.size(customHeight: custom.height)
        let scale = min(
            max(0.6, min(2.5, self.scale(record.kind))), record.area.width / wanted.width,
            record.area.height / wanted.height)
        let size = NSSize(width: wanted.width * scale, height: wanted.height * scale)
        let position = positions[record.key] ?? .initial(record.kind)
        let frame = position.frame(size: size, area: record.area)
        if let face = record.face, face.scale != scale || face.size != size {
            face.scale = scale
            face.size = size
        }
        if let web = record.custom?.view, web.pageZoom != scale { web.pageZoom = scale }
        record.drag?.dragBounds = record.area
        if record.window.frame != frame { record.window.setFrame(frame, display: false) }
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
        NotificationCenter.default.addObserver(
            self, selector: #selector(occlusionChanged(_:)),
            name: NSWindow.didChangeOcclusionStateNotification, object: nil)
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
        pendingSave?.cancel()
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }
    private func persist() {
        if let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: "desktopWidgets")
        }
    }
    private func scheduleSave() {
        pendingSave?.cancel()
        pendingSave = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.saveLayout()
        }
    }
    private func saveLayout() {
        pendingSave?.cancel()
        pendingSave = nil
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
    @objc private func rebuild() { reconcile() }
    // Updates are skipped while every widget is covered. Bring the clock up to date the moment one
    // is uncovered; metrics follow on the next 500 ms tick.
    @objc private func occlusionChanged(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
            window.occlusionState.contains(.visible),
            records.contains(where: { $0.window === window })
        else { return }
        readings.refresh(stats: false)
    }
    private func reconcile(recreateCustom: Bool = false) {
        var wanted: [(key: String, kind: WidgetKind, area: NSRect)] = []
        if !sleeping, !inactive {
            let screens =
                settings.allDisplays ? NSScreen.screens : Array(NSScreen.screens.prefix(1))
            for screen in screens {
                let display =
                    (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                    as? NSNumber)?.stringValue ?? "main"
                for kind in WidgetKind.allCases where enabled(kind) {
                    wanted.append((kind.rawValue + "@" + display, kind, screen.visibleFrame))
                }
            }
        }
        records.removeAll { record in
            let keep =
                wanted.contains { $0.key == record.key }
                && !(recreateCustom && record.kind == .custom)
            if !keep { close(record) }
            return !keep
        }
        for item in wanted {
            if let record = records.first(where: { $0.key == item.key }) {
                record.area = item.area
                layout(record)
                applyEditing(record)
            } else {
                records.append(makeRecord(key: item.key, kind: item.kind, area: item.area))
            }
        }
        if editing {
            if editPanel == nil { showEditPanel() }
        } else {
            editPanel?.close()
            editPanel = nil
        }
        updateTimer()
    }
    private func close(_ record: WindowRecord) {
        record.custom?.stop()
        record.drag?.removeFromSuperview()
        record.window.contentView = nil
        record.window.close()
    }
    private func makeRecord(key: String, kind: WidgetKind, area: NSRect) -> WindowRecord {
        let window = makeWindow(NSRect(origin: area.origin, size: NSSize(width: 1, height: 1)))
        window.title = kind.title
        window.identifier = NSUserInterfaceItemIdentifier("widget-" + key)
        let wanted = kind.size(customHeight: custom.height)
        let container = NSView(frame: NSRect(origin: .zero, size: wanted))
        let content: NSView
        var face: WidgetFaceState?
        var customHost: CustomWidgetHost?
        if kind == .custom {
            let host = CustomWidgetHost(package: custom, size: wanted, scale: 1)
            host.error = { [weak self] in self?.error = $0 }
            host.onReady = { [weak self, weak host] in
                if let self { host?.update(self.readings) }
            }
            customHost = host
            content = host.view
        } else {
            let state = WidgetFaceState(scale: 1, size: wanted)
            let host = NSHostingView(
                rootView: WidgetFaceRoot(readings: readings, kind: kind, state: state))
            host.sizingOptions = []
            face = state
            content = host
        }
        content.frame = container.bounds
        content.autoresizingMask = [.width, .height]
        container.addSubview(content)
        window.contentView = container
        let record = WindowRecord(
            kind: kind, key: key, area: area, window: window, container: container, face: face,
            custom: customHost)
        layout(record)
        applyEditing(record)
        window.orderFrontRegardless()
        return record
    }
    private func applyEditing(_ record: WindowRecord) {
        let level = NSWindow.Level(
            rawValue: editing
                ? Int(CGWindowLevelForKey(.desktopIconWindow)) + 1
                : Int(CGWindowLevelForKey(.desktopWindow)) + 2)
        if record.window.level != level {
            record.window.level = level
            record.window.orderFrontRegardless()
        }
        record.window.ignoresMouseEvents = !editing
        if editing, record.drag == nil {
            let drag = WidgetDragSurface(frame: record.container.bounds)
            drag.dragBounds = record.area
            drag.autoresizingMask = [.width, .height]
            drag.setAccessibilityLabel("Drag " + record.kind.title)
            drag.didDrag = { [weak self, weak record] moved in
                guard let self, let record else { return }
                let position = WidgetPosition.from(frame: moved, area: record.area)
                self.positions[record.key] = position
                self.saveLayout()
                record.window.setFrame(
                    position.frame(size: record.window.frame.size, area: record.area),
                    display: true)
            }
            record.container.addSubview(drag)
            record.drag = drag
        } else if !editing, let drag = record.drag {
            drag.removeFromSuperview()
            record.drag = nil
        }
    }
    // Clock and date only need a tick per minute; live metrics need 500 ms sampling. The timer is
    // only replaced when that requirement changes, so unrelated edits keep the sample baseline.
    private func updateTimer() {
        let stats: Bool? =
            records.isEmpty
            ? nil : enabled(.cpu) || enabled(.memory) || enabled(.network) || customEnabled
        guard stats != timerSamplesStats || (stats != nil && timer == nil) else { return }
        timer?.invalidate()
        timer = nil
        timerSamplesStats = stats
        guard let stats else { return }
        if stats { readings.resetBaseline() }
        refresh()
        let interval: TimeInterval = stats ? 0.5 : 60
        let firstFire =
            stats
            ? Date().addingTimeInterval(0.5)
            : Date(timeIntervalSince1970: (floor(Date().timeIntervalSince1970 / 60) + 1) * 60)
        let timer = Timer(fire: firstFire, interval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer.tolerance = stats ? 0.05 : 1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
    private func makeWindow(_ frame: NSRect) -> NSWindow {
        let window = DesktopWindow(
            contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
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
        // Widgets sit on the desktop. When every one is covered and the library is not in front,
        // nobody can see an update; skip the sampling and redraw work entirely.
        guard
            NSApp.isActive
                || records.contains(where: { $0.window.occlusionState.contains(.visible) })
        else { return }
        readings.refresh(
            stats: enabled(.cpu) || enabled(.memory) || enabled(.network) || customEnabled)
        for record in records { record.custom?.update(readings) }
    }
    func applyCustom(_ package: CustomWidgetPackage) {
        do {
            custom = try package.validated()
            defaults.set(try JSONEncoder().encode(custom), forKey: "customWidgetPackage")
            error = nil
            reconcile(recreateCustom: true)
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
