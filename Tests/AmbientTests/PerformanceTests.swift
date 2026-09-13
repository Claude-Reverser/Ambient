import AVFoundation
import AppKit
import XCTest

@testable import Ambient

final class PerformanceTests: XCTestCase {
    @MainActor func testOriginalQualityNeverReencodesOrCreatesCache() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("original.mp4")
        let bytes = Data("source must not be touched".utf8)
        try bytes.write(to: source)
        let cache = root.appendingPathComponent("cache")
        let item = Wallpaper(title: "Original", path: source.path, root: root.path, kind: .video)
        let resolved = try await VideoOptimizer(directory: cache).preparedURL(
            for: item, profile: .original)
        XCTAssertEqual(resolved, source)
        XCTAssertEqual(try Data(contentsOf: source), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.path))
    }
    @MainActor func testDefaultQualityPreservesOriginal() throws {
        let suiteName = "AmbientTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let library = Library(
            storage: FileManager.default.temporaryDirectory.appendingPathComponent(
                UUID().uuidString), defaults: defaults)
        XCTAssertEqual(library.profile, .original)
        library.stop()
    }
    func testNativeGIFHasARealThumbnail() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString + ".gif")
        let data = try XCTUnwrap(
            Data(base64Encoded: "R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7"))
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let item = Wallpaper(
            title: "GIF", path: url.path, root: url.deletingLastPathComponent().path, kind: .web)
        let image = await ImageLoader.shared.thumbnail(item)
        XCTAssertNotNil(
            image, "GIF thumbnails must decode the GIF instead of looking for a web-project preview"
        )
    }
    @MainActor func testFavoritesPersistAcrossLibraryInstances() throws {
        let suiteName = "AmbientTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let storage = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        let item = Wallpaper(title: "Favorite", path: "/test.png", root: "/", kind: .image)
        let first = Library(storage: storage, defaults: defaults)
        first.toggleFavorite(item)
        let second = Library(storage: storage, defaults: defaults)
        XCTAssertTrue(second.favorites.contains(item.id))
        second.toggleFavorite(item)
        let third = Library(storage: storage, defaults: defaults)
        XCTAssertFalse(third.favorites.contains(item.id))
    }
    func testWebAndGIFFiltersAreDistinct() {
        let gif = Wallpaper(title: "GIF", path: "/test.gif", root: "/", kind: .web)
        let web = Wallpaper(title: "Web", path: "/index.html", root: "/", kind: .web)
        XCTAssertTrue(WallpaperFilter.gif.accepts(gif))
        XCTAssertFalse(WallpaperFilter.web.accepts(gif))
        XCTAssertTrue(WallpaperFilter.web.accepts(web))
        XCTAssertFalse(WallpaperFilter.gif.accepts(web))
        XCTAssertTrue(WallpaperFilter.all.accepts(gif))
    }
    func testPausePrecedenceAndRecovery() {
        var state = PlaybackConditions()
        XCTAssertNil(state.reason(conserve: true, pauseOnBattery: true))
        state.onBattery = true
        XCTAssertEqual(state.reason(conserve: true, pauseOnBattery: true), .battery)
        XCTAssertNil(state.reason(conserve: true, pauseOnBattery: false))
        state.memoryPressure = true
        XCTAssertEqual(state.reason(conserve: false, pauseOnBattery: false), .memory)
        state.sleeping = true
        XCTAssertEqual(state.reason(conserve: false, pauseOnBattery: false), .sleep)
        state.manual = true
        XCTAssertEqual(state.reason(conserve: true, pauseOnBattery: true), .manual)
        state = PlaybackConditions()
        state.hot = true
        XCTAssertEqual(state.reason(conserve: true, pauseOnBattery: false), .thermal)
        XCTAssertNil(state.reason(conserve: false, pauseOnBattery: false))
    }
    func testProfileSizesDoNotUpscaleAndAreEncoderAligned() {
        XCTAssertEqual(
            QualityProfile.balanced.targetSize(CGSize(width: 3840, height: 2160)),
            CGSize(width: 2560, height: 1440))
        XCTAssertEqual(
            QualityProfile.eco.targetSize(CGSize(width: 2160, height: 3840)),
            CGSize(width: 720, height: 1280))
        XCTAssertEqual(
            QualityProfile.balanced.targetSize(CGSize(width: 640, height: 480)),
            CGSize(width: 640, height: 480))
        let odd = QualityProfile.eco.targetSize(CGSize(width: 1921, height: 1081))
        XCTAssertEqual(Int(odd.width) % 2, 0)
        XCTAssertEqual(Int(odd.height) % 2, 0)
    }
    func testGIFKeepsWallClockTimingWhenFramesAreSkipped() {
        let timeline = GIFTimeline(delays: [0.1, 0.2, 0.3])
        XCTAssertEqual(timeline.index(at: 0), 0)
        XCTAssertEqual(timeline.index(at: 0.15), 1)
        XCTAssertEqual(timeline.index(at: 0.55), 2)
        XCTAssertEqual(timeline.index(at: 0.65), 0)
        XCTAssertEqual(timeline.index(at: 15.15), 1)
    }
    @MainActor func testCacheEvictsOldestWithinBudget() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let old = directory.appendingPathComponent("old.mp4")
        let recent = directory.appendingPathComponent("recent.mp4")
        try Data(repeating: 0, count: 100).write(to: old)
        try Data(repeating: 0, count: 100).write(to: recent)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: old.path)
        try VideoOptimizer(directory: directory).trim(to: 100)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recent.path))
    }
    @MainActor func testRendererReleasesResourcesAndResumes() async throws {
        _ = NSApplication.shared
        guard let screen = NSScreen.screens.first else {
            throw XCTSkip("Requires a display session")
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString + ".png")
        let image = NSImage(size: CGSize(width: 32, height: 32), flipped: false) { rect in
            NSColor.blue.setFill()
            rect.fill()
            return true
        }
        try XCTUnwrap(image.tiffRepresentation).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let item = Wallpaper(
            title: "Test", path: url.path, root: url.deletingLastPathComponent().path, kind: .image)
        let renderer = Renderer(wallpaper: item, screen: screen, initiallyPaused: true) {
            XCTFail($0)
        }
        XCTAssertFalse(renderer.hasLiveResources)
        renderer.setPaused(false)
        XCTAssertTrue(renderer.hasLiveResources)
        renderer.setPaused(true)
        XCTAssertFalse(renderer.hasLiveResources)
        XCTAssertNil(renderer.window.contentView)
        renderer.setPaused(false)
        XCTAssertTrue(renderer.hasLiveResources)
        renderer.stop()
        XCTAssertFalse(renderer.hasLiveResources)
        renderer.setPaused(false)
        XCTAssertFalse(renderer.hasLiveResources, "Stopped renderers must not restart")
    }
    func testLargeStillIsDownsampled() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString + ".tiff")
        let image = NSImage(size: CGSize(width: 4000, height: 2000), flipped: false) { rect in
            NSColor.blue.setFill()
            rect.fill()
            return true
        }
        try XCTUnwrap(image.tiffRepresentation).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let downsampled = await ImageLoader.shared.image(url, maxPixel: 480)
        XCTAssertEqual(downsampled?.size.width, 480)
        XCTAssertEqual(downsampled?.size.height, 240)
    }
}
