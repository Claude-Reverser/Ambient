import AppKit
import Observation
import WebKit
import XCTest

@testable import Ambient

final class WidgetHealthTests: XCTestCase {
    func testPressureRecoverySurvivesWarningAndResetsOnCritical() {
        var recovery = MemoryPressureRecovery()
        recovery.critical()
        XCTAssertFalse(recovery.check(level: 2, now: 0))
        XCTAssertFalse(recovery.check(level: 2, now: 19))
        XCTAssertTrue(recovery.check(level: 2, now: 20))
        XCTAssertFalse(recovery.paused)
        recovery.critical()
        XCTAssertFalse(recovery.check(level: 1, now: 30))
        XCTAssertFalse(recovery.check(level: 4, now: 45))
        XCTAssertFalse(recovery.check(level: 1, now: 50))
        XCTAssertFalse(recovery.check(level: nil, now: 60))
        XCTAssertFalse(recovery.check(level: 1, now: 70))
        XCTAssertTrue(recovery.check(level: 1, now: 90))
    }
    func testStallRecoveryIsBoundedAndLoopChangesAreProgress() {
        var health = VideoHealth()
        let first = NSObject()
        let next = NSObject()
        XCTAssertEqual(
            health.inspect(position: 1, item: ObjectIdentifier(first), failed: false), .none)
        for _ in 0..<2 {
            XCTAssertEqual(
                health.inspect(position: 1, item: ObjectIdentifier(first), failed: false), .none)
        }
        XCTAssertEqual(
            health.inspect(position: 1, item: ObjectIdentifier(first), failed: false), .resume)
        XCTAssertEqual(
            health.inspect(position: 1, item: ObjectIdentifier(next), failed: false), .none)
        for _ in 0..<3 {
            XCTAssertEqual(health.inspect(position: 1, item: nil, failed: true), .rebuild)
        }
        XCTAssertEqual(health.inspect(position: 1, item: nil, failed: true), .failed)
    }
    @MainActor func testCpuDeltaAndBoundedNetworkHistory() {
        XCTAssertEqual(
            SystemReadings.cpuPercent(ticks: [20, 10, 60, 10], previous: [0, 0, 0, 0]), 40)
        XCTAssertNil(SystemReadings.cpuPercent(ticks: [1, 1, 1, 1], previous: [1, 1, 1, 1]))
        XCTAssertEqual(
            SystemReadings.cpuPercent(
                ticks: [0, 0, 0, 0], previous: [UInt32.max, UInt32.max, UInt32.max, UInt32.max]), 75
        )
        var history = UsageHistory()
        for index in 0..<500 {
            history.append(UsageSample(cpu: 10, memory: 50, download: Double(index), upload: 1))
        }
        XCTAssertEqual(history.samples.count, 120)
        XCTAssertEqual(history.samples.first?.download, 380)
    }
    func testExistingSettingsAndShareableWidgetRoundTrip() throws {
        let old = Data(
            #"{"clock":true,"stats":true,"scale":1.8,"x":0.2,"y":0.7,"allDisplays":false}"#.utf8)
        let settings = try JSONDecoder().decode(DesktopWidgetSettings.self, from: old)
        XCTAssertEqual(settings.scale, 1.8)
        XCTAssertTrue(settings.stats)
        let package = try JSONDecoder().decode(
            CustomWidgetPackage.self, from: JSONEncoder().encode(CustomWidgetPackage.starter)
        ).validated()
        XCTAssertEqual(package, .starter)
        var invalid = package
        invalid.version = 2
        XCTAssertThrowsError(try invalid.validated())
        invalid = package
        invalid.html = String(repeating: "x", count: 262_145)
        XCTAssertThrowsError(try invalid.validated())
    }
    @MainActor func testCustomHTMLBindsMetricsWithoutPageScripts() async throws {
        _ = NSApplication.shared
        var package = CustomWidgetPackage.starter
        package.html += "<script>document.body.dataset.unwanted='yes';</script>"
        let host = CustomWidgetHost(
            package: package, size: NSSize(width: 360, height: 220), scale: 1.5)
        defer { host.stop() }
        var failure: String?
        host.error = { failure = $0 }
        for _ in 0..<150 {
            if host.ready { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(host.ready, "HTML must finish loading")
        let readings = SystemReadings()
        readings.refresh(stats: true)
        host.update(readings)
        var time = ""
        for _ in 0..<30 {
            try await Task.sleep(for: .milliseconds(100))
            time =
                try await host.view.evaluateJavaScript(
                    "document.querySelector('[data-ambient=time]').textContent", in: nil,
                    contentWorld: .defaultClient) as? String ?? ""
            if !time.isEmpty { break }
        }
        XCTAssertFalse(
            time.isEmpty, "Trusted metric bindings must work with page JavaScript disabled")
        let scriptRan =
            try await host.view.evaluateJavaScript(
                "document.body.dataset.unwanted || 'no'", in: nil, contentWorld: .defaultClient)
            as? String
        XCTAssertEqual(scriptRan, "no")
        XCTAssertNil(failure)
    }
    @MainActor func testRealVideoRecoversUnrequestedPauseButRespectsManualPause() async throws {
        guard let path = ProcessInfo.processInfo.environment["AMBIENT_VIDEO_FIXTURE"] else {
            throw XCTSkip("Set AMBIENT_VIDEO_FIXTURE for decoder recovery test")
        }
        _ = NSApplication.shared
        guard let screen = NSScreen.screens.first else { throw XCTSkip("Requires a screen") }
        let wallpaper = Wallpaper(
            title: "Recovery test", path: path,
            root: URL(fileURLWithPath: path).deletingLastPathComponent().path, kind: .video)
        var events: [String] = []
        let renderer = Renderer(
            wallpaper: wallpaper, screen: screen, profile: .original,
            onEvent: { events.append($0) }, onError: { XCTFail($0) })
        defer { renderer.stop() }
        try await Task.sleep(for: .seconds(3))
        let player = try XCTUnwrap(renderer.player)
        player.pause()
        try await Task.sleep(for: .seconds(10))
        XCTAssertGreaterThan(player.rate, 0)
        XCTAssertTrue(events.contains { $0.contains("resuming") })
        renderer.setPaused(true)
        for _ in 0..<10 { renderer.checkVideoHealth() }
        XCTAssertNil(renderer.player)
        XCTAssertFalse(renderer.hasLiveResources)
    }

    func testDragPositionsRoundTripAndStayOnScreen() {
        let area = NSRect(x: -1440, y: 30, width: 1440, height: 870)
        let size = NSSize(width: 286, height: 120)
        let position = WidgetPosition(x: 0.25, y: 0.75)
        let frame = position.frame(size: size, area: area)
        let restored = WidgetPosition.from(frame: frame, area: area)
        XCTAssertEqual(restored.x, position.x, accuracy: 0.0001)
        XCTAssertEqual(restored.y, position.y, accuracy: 0.0001)
        let outside = WidgetPosition.from(
            frame: NSRect(x: -3000, y: 2000, width: 286, height: 120), area: area)
        let clamped = outside.frame(size: size, area: area)
        XCTAssertTrue(area.contains(clamped))
    }
    @MainActor func testSeparateWidgetsDragPersistsWithoutMovingOtherWidgets() throws {
        _ = NSApplication.shared
        let suite = "WidgetDragTest-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        guard !NSScreen.screens.isEmpty else { throw XCTSkip("Requires an active display session") }
        let manager = DesktopWidgets(defaults: defaults)
        manager.setEnabled(.cpu, true)
        manager.setEnabled(.network, true)
        defer {
            manager.setEditing(false)
            manager.setEnabled(.cpu, false)
            manager.setEnabled(.network, false)
        }
        XCTAssertEqual(manager.enabledCount, 2)
        manager.setEditing(true)
        XCTAssertTrue(manager.editing)
        let network = try XCTUnwrap(
            manager.windows.first { $0.identifier?.rawValue.hasPrefix("widget-network@") == true })
        let cpu = try XCTUnwrap(
            manager.windows.first { $0.identifier?.rawValue.hasPrefix("widget-cpu@") == true })
        let cpuFrame = cpu.frame
        XCTAssertFalse(network.ignoresMouseEvents)
        let drag = try XCTUnwrap(
            network.contentView?.subviews.compactMap { $0 as? WidgetDragSurface }.first)
        let target = network.frame.offsetBy(dx: -80, dy: 60)
        let start = NSPoint(x: network.frame.midX, y: network.frame.midY)
        drag.beginDrag(at: start)
        drag.drag(to: NSPoint(x: start.x - 80, y: start.y + 60))
        XCTAssertEqual(network.frame.origin.x, target.origin.x, accuracy: 1)
        drag.endDrag()
        XCTAssertEqual(network.frame.origin.x, target.origin.x, accuracy: 1)
        XCTAssertEqual(cpu.frame, cpuFrame)
        let saved = try XCTUnwrap(defaults.data(forKey: "widgetPositions"))
        XCTAssertEqual(
            try JSONDecoder().decode([String: WidgetPosition].self, from: saved).count, 1)
        manager.setEditing(false)
        let locked = try XCTUnwrap(
            manager.windows.first { $0.identifier?.rawValue.hasPrefix("widget-network@") == true })
        XCTAssertTrue(locked.ignoresMouseEvents)
        XCTAssertEqual(locked.frame.origin.x, target.origin.x, accuracy: 1)
        XCTAssertFalse(locked.contentView?.subviews.contains { $0 is WidgetDragSurface } ?? true)
    }

    @MainActor func testResizingReusesWindowsAndOtherWidgetContent() throws {
        _ = NSApplication.shared
        let suite = "WidgetResizeTest-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        guard !NSScreen.screens.isEmpty else { throw XCTSkip("Requires an active display session") }
        let manager = DesktopWidgets(defaults: defaults)
        manager.setEnabled(.cpu, true)
        manager.setEnabled(.network, true)
        defer {
            manager.setEnabled(.cpu, false)
            manager.setEnabled(.network, false)
        }
        let network = try XCTUnwrap(manager.windows.first { $0.title == "Network graph" })
        let cpu = try XCTUnwrap(manager.windows.first { $0.title == "CPU" })
        let cpuContent = cpu.contentView
        for index in 0..<50 { manager.setScale(.network, 1 + Double(index) / 100) }
        XCTAssertTrue(manager.windows.contains { $0 === network })
        XCTAssertTrue(manager.windows.contains { $0 === cpu })
        XCTAssertTrue(cpu.contentView === cpuContent)
        XCTAssertEqual(network.frame.width, 286 * 1.49, accuracy: 1)
        manager.setEditing(true)
        XCTAssertTrue(
            manager.windows.allSatisfy { $0.level.rawValue < NSWindow.Level.normal.rawValue },
            "Edit widgets must never intercept clicks over ordinary apps")
        manager.setEditing(false)
    }
    @MainActor func testSystemSamplingDoesNotInvalidateClockForUnchangedMinute() {
        let readings = SystemReadings()
        let minute = floor(readings.date.timeIntervalSince1970 / 60)
        var invalidated = false
        withObservationTracking {
            _ = readings.date
        } onChange: {
            invalidated = true
        }
        readings.refresh(stats: true)
        if floor(Date().timeIntervalSince1970 / 60) == minute { XCTAssertFalse(invalidated) }
    }

    @MainActor func testDraggingPreservesGrabOffsetAndCommitsOnlyOnRelease() {
        _ = NSApplication.shared
        let window = DesktopWindow(
            contentRect: NSRect(x: 100, y: 100, width: 140, height: 74), styleMask: .borderless,
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let drag = WidgetDragSurface(frame: NSRect(x: 0, y: 0, width: 140, height: 74))
        drag.dragBounds = NSRect(x: 0, y: 0, width: 1000, height: 800)
        window.contentView = drag
        var saved: [NSRect] = []
        drag.didDrag = { saved.append($0) }
        drag.beginDrag(at: NSPoint(x: 130, y: 115))
        XCTAssertTrue(saved.isEmpty)
        drag.drag(to: NSPoint(x: 330, y: 165))
        XCTAssertEqual(window.frame.origin, NSPoint(x: 300, y: 150))
        drag.drag(to: NSPoint(x: 340, y: 170))
        XCTAssertEqual(window.frame.origin, NSPoint(x: 310, y: 155))
        XCTAssertTrue(saved.isEmpty)
        drag.endDrag()
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved[0].origin, NSPoint(x: 310, y: 155))
        drag.beginDrag(at: NSPoint(x: 340, y: 170))
        drag.drag(to: NSPoint(x: 330, y: 165))
        drag.endDrag()
        XCTAssertEqual(saved.last?.origin, NSPoint(x: 300, y: 150))
    }

}
