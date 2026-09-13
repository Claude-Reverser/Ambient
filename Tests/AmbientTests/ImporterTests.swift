import XCTest

@testable import Ambient

final class ImporterTests: XCTestCase {
    var folder: URL!
    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: folder) }
    func put(_ name: String, _ content: String = "") throws {
        try Data(content.utf8).write(to: folder.appendingPathComponent(name))
    }
    func testVideoProject() throws {
        try put("movie.mp4")
        try put("project.json", #"{"type":"video","file":"movie.mp4","title":"Ocean"}"#)
        let item = try WallpaperImporter.resolve(folder)
        XCTAssertEqual(item.kind, .video)
        XCTAssertEqual(item.title, "Ocean")
    }
    func testSceneNeedsArchive() throws {
        try put("project.json", #"{"type":"scene","file":"scene.pkg"}"#)
        XCTAssertThrowsError(try WallpaperImporter.resolve(folder)) {
            XCTAssertTrue($0.localizedDescription.contains("loose scene"))
        }
    }
    func testTraversalRejected() throws {
        try put("project.json", #"{"type":"web","file":"../outside.html"}"#)
        XCTAssertThrowsError(try WallpaperImporter.resolve(folder)) {
            XCTAssertTrue($0.localizedDescription.contains("inside"))
        }
    }
    func testSymlinkEscapeRejected() throws {
        let outside = folder.deletingLastPathComponent().appendingPathComponent(
            UUID().uuidString + ".html")
        try Data().write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(
            at: folder.appendingPathComponent("escape.html"), withDestinationURL: outside)
        try put("project.json", #"{"type":"web","file":"escape.html"}"#)
        XCTAssertThrowsError(try WallpaperImporter.resolve(folder)) {
            XCTAssertTrue($0.localizedDescription.contains("inside"))
        }
    }
    func testWebFolder() throws {
        try put("index.html")
        XCTAssertEqual(try WallpaperImporter.resolve(folder).kind, .web)
    }
    func testUnsupportedContainer() throws {
        try put("movie.mkv")
        XCTAssertThrowsError(
            try WallpaperImporter.resolve(folder.appendingPathComponent("movie.mkv")))
    }
    func testMissingEntry() throws {
        try put("project.json", #"{"type":"video","file":"gone.mp4"}"#)
        XCTAssertThrowsError(try WallpaperImporter.resolve(folder))
    }
}
