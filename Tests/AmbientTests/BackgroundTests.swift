import XCTest

@testable import Ambient

final class BackgroundTests: XCTestCase {
    @MainActor func testQuitPreservesWallpaperWhileStopClearsIt() throws {
        let name = "AmbientBackgroundTest-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: "manuallyPaused")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("wallpaper.png")
        try Data().write(to: file)
        let library = Library(
            storage: directory.appendingPathComponent("library.json"), defaults: defaults)
        XCTAssertTrue(library.manuallyPaused)
        let item = Wallpaper(
            title: "Paused test", path: file.path, root: directory.path, kind: .image)
        library.apply(item)
        XCTAssertEqual(defaults.string(forKey: "activeWallpaper"), item.id.uuidString)
        library.stop(preserveSelection: true)
        XCTAssertEqual(defaults.string(forKey: "activeWallpaper"), item.id.uuidString)
        library.stop()
        XCTAssertNil(defaults.string(forKey: "activeWallpaper"))
    }
}
