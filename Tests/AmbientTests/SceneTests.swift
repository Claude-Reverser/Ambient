import Compression
import ImageIO
import MetalKit
import UniformTypeIdentifiers
import XCTest

@testable import Ambient

final class SceneTests: XCTestCase {
    static func uint(_ value: Int) -> Data {
        var v = UInt32(value).littleEndian
        return withUnsafeBytes(of: &v) { Data($0) }
    }
    static func pkg(_ entries: [(String, Data)]) -> Data {
        var data = uint(8) + Data("PKGV0014".utf8) + uint(entries.count)
        var offset = 0
        for (name, content) in entries {
            data += uint(name.utf8.count) + Data(name.utf8) + uint(offset) + uint(content.count)
            offset += content.count
        }
        for (_, content) in entries { data += content }
        return data
    }
    static func texture(_ pixels: Data, width: Int = 4, height: Int = 4, compressed: Bool = false)
        -> Data
    {
        var stored = pixels
        if compressed {
            var output = Data(count: pixels.count + 100)
            let count = output.withUnsafeMutableBytes { out in
                pixels.withUnsafeBytes { input in
                    compression_encode_buffer(
                        out.bindMemory(to: UInt8.self).baseAddress!, out.count,
                        input.bindMemory(to: UInt8.self).baseAddress!, input.count, nil,
                        COMPRESSION_LZ4_RAW)
                }
            }
            stored = output.prefix(count)
        }
        var result = Data("TEXV0005\0TEXI0001\0".utf8)
        for value in [0, 2, width, height, width, height, 0] { result += uint(value) }
        result += Data("TEXB0003\0".utf8)
        for value in [
            1, Int(UInt32.max), 1, width, height, compressed ? 1 : 0, pixels.count, stored.count,
        ] { result += uint(value) }
        result += stored
        return result
    }
    static func staticPackage() throws -> Data {
        let scene: [String: Any] = [
            "version": 1, "general": ["orthogonalprojection": ["width": 4, "height": 4]],
            "objects": [
                [
                    "image": "models/image.json", "size": "4 4", "origin": "2 2 0",
                    "scale": "1 1 1", "angles": "0 0 0", "color": "1 1 1", "effects": [],
                ]
            ],
        ]
        let model: [String: Any] = ["material": "materials/image.json"]
        let material: [String: Any] = [
            "passes": [["shader": "genericimage2", "textures": ["image"]]]
        ]
        var pixels = Data()
        for y in 0..<4 {
            for x in 0..<4 {
                pixels.append(
                    contentsOf: y < 2
                        ? (x < 2 ? [255, 0, 0, 255] : [0, 255, 0, 255])
                        : (x < 2 ? [0, 0, 255, 255] : [255, 255, 255, 255]))
            }
        }
        return pkg([
            ("scene.json", try JSONSerialization.data(withJSONObject: scene)),
            ("models/image.json", try JSONSerialization.data(withJSONObject: model)),
            ("materials/image.json", try JSONSerialization.data(withJSONObject: material)),
            ("materials/image.tex", texture(pixels)),
        ])
    }
    func testArchiveBoundsAndPaths() throws {
        let safe = try ScenePackage(data: Self.pkg([("scene.json", Data("{}".utf8))]))
        XCTAssertEqual(try safe.entry("scene.json"), Data("{}".utf8))
        XCTAssertThrowsError(try ScenePackage(data: Self.pkg([("../escape", Data())])))
        XCTAssertThrowsError(
            try ScenePackage(data: Self.pkg([("same", Data()), ("same", Data())])))
        XCTAssertThrowsError(try ScenePackage(data: Self.pkg([("file", Data([1, 2]))]).dropLast()))
        XCTAssertThrowsError(try ScenePackage(data: Data([0, 1, 2])))
    }
    func testRawAndLZ4TextureDecode() throws {
        let pixels = Data(repeating: 127, count: 4 * 4 * 4)
        for compressed in [false, true] {
            let texture = try SceneTexture(data: Self.texture(pixels, compressed: compressed))
            XCTAssertEqual(texture.width, 4)
            guard case .raw(let decoded, let channels) = texture.payload else {
                return XCTFail("Expected raw texture")
            }
            XCTAssertEqual(decoded, pixels)
            XCTAssertEqual(channels, 4)
        }
        XCTAssertThrowsError(try SceneTexture(data: Self.texture(Data([0]), width: 8193)))
    }
    func testRejectsUnsupportedLayers() throws {
        let package = try ScenePackage(data: Self.staticPackage())
        var root = try package.json("scene.json")
        root["objects"] =
            (root["objects"] as! [[String: Any]]) + (root["objects"] as! [[String: Any]])
        let modified = Self.pkg(
            try package.entryNames.map {
                (
                    $0,
                    $0 == "scene.json"
                        ? try JSONSerialization.data(withJSONObject: root) : try package.entry($0)
                )
            })
        XCTAssertThrowsError(try SceneDescription(package: ScenePackage(data: modified)))
    }
    static func render(_ resources: SceneResources, time: Double, width: Int, height: Int) throws
        -> Data
    {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget]
        descriptor.storageMode = .shared
        let texture = try XCTUnwrap(resources.device.makeTexture(descriptor: descriptor))
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        let command = try XCTUnwrap(resources.queue.makeCommandBuffer())
        let encoder = try XCTUnwrap(command.makeRenderCommandEncoder(descriptor: pass))
        resources.encode(encoder, time: time, size: CGSize(width: width, height: height))
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        XCTAssertEqual(command.status, .completed)
        var output = Data(count: width * height * 4)
        output.withUnsafeMutableBytes {
            texture.getBytes(
                $0.baseAddress!, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0)
        }
        return output
    }
    func testMetalOrientationAndColor() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal required") }
        let resources = try SceneResources(
            package: ScenePackage(data: Self.staticPackage()), device: device)
        let image = try Self.render(resources, time: 0, width: 4, height: 4)
        XCTAssertEqual(
            Array(image[0..<4]), [0, 0, 255, 255],
            "Top-left must be red, not vertically flipped or channel-swapped")
        XCTAssertEqual(Array(image[12..<16]), [0, 255, 0, 255])
        XCTAssertEqual(Array(image[48..<52]), [255, 0, 0, 255])
        XCTAssertEqual(MemoryLayout<SceneResources.Uniforms>.stride, 64)
    }
    func testFlowPhaseStaysPreciseAfterLongUptime() {
        XCTAssertEqual(SceneResources.fract(1_000_000.25), 0.25)
        XCTAssertEqual(SceneResources.fract(2_592_000.75), 0.75)
        XCTAssertEqual(SceneResources.fract(3), 0)
    }
    @MainActor func testScenePauseReleasesAndSharingUsesSameTextures() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let screen = NSScreen.screens.first
        else { throw XCTSkip("Metal/display required") }
        _ = NSApplication.shared
        let resources = try SceneResources(
            package: ScenePackage(data: Self.staticPackage()), device: device)
        let item = Wallpaper(title: "Test", path: "/test.pkg", root: "/", kind: .scene)
        let first = Renderer(wallpaper: item, screen: screen, sceneResources: resources) {
            XCTFail($0)
        }
        let second = Renderer(wallpaper: item, screen: screen, sceneResources: resources) {
            XCTFail($0)
        }
        XCTAssertTrue(first.scene?.resources === second.scene?.resources)
        first.setPaused(true)
        second.setPaused(true)
        XCTAssertFalse(first.hasLiveResources)
        XCTAssertFalse(second.hasLiveResources)
        first.stop()
        second.stop()
    }
    func testLocalWavesRendersAnimatedFullResolution() throws {
        guard let path = ProcessInfo.processInfo.environment["AMBIENT_SCENE_FIXTURE"],
            let device = MTLCreateSystemDefaultDevice()
        else { throw XCTSkip("Set AMBIENT_SCENE_FIXTURE to test a local package") }
        let resources = try SceneResources(
            package: ScenePackage(url: URL(fileURLWithPath: path)), device: device)
        XCTAssertEqual(resources.description.width, 3840)
        XCTAssertEqual(resources.description.height, 2160)
        XCTAssertEqual(resources.textures.first?.width, 3840)
        XCTAssertEqual(resources.textures.first?.height, 2160)
        XCTAssertTrue(resources.description.animated)
        XCTAssertTrue(
            resources.textures.allSatisfy { $0.mipmapLevelCount == 1 },
            "Water Flow must not sample synthesized image or vector-map mipmaps")
        XCTAssertEqual(resources.description.speed, 0.3, accuracy: 0.0001)
        XCTAssertEqual(resources.description.strength, 1)
        XCTAssertEqual(resources.description.phaseScale, 2)
        let a = try Self.render(resources, time: 0.3, width: 1280, height: 720)
        let b = try Self.render(resources, time: 1.3, width: 1280, height: 720)
        let change =
            zip(a, b).reduce(0.0) { $0 + abs(Double($1.0) - Double($1.1)) } / Double(a.count)
        XCTAssertGreaterThan(change, 0.1, "The flow shader must produce visible motion")
        if let directory = ProcessInfo.processInfo.environment["AMBIENT_SCENE_QA"] {
            for (name, data) in [("waves-0.3", a), ("waves-1.3", b)] {
                let url = URL(fileURLWithPath: directory).appendingPathComponent(name + ".png")
                let provider = try XCTUnwrap(CGDataProvider(data: data as CFData))
                let image = try XCTUnwrap(
                    CGImage(
                        width: 1280, height: 720, bitsPerComponent: 8, bitsPerPixel: 32,
                        bytesPerRow: 1280 * 4, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGBitmapInfo(
                            rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                                | CGBitmapInfo.byteOrder32Little.rawValue), provider: provider,
                        decode: nil, shouldInterpolate: true, intent: .defaultIntent))
                let destination = try XCTUnwrap(
                    CGImageDestinationCreateWithURL(
                        url as CFURL, UTType.png.identifier as CFString, 1, nil))
                CGImageDestinationAddImage(destination, image, nil)
                XCTAssertTrue(CGImageDestinationFinalize(destination))
            }
        }
    }
}
