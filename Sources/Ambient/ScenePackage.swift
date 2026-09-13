import Compression
import CryptoKit
import Foundation

enum SceneError: LocalizedError {
    case invalid(String)
    case unsupported(String)
    var errorDescription: String? {
        switch self {
        case .invalid(let text): return "Invalid scene package: \(text)"
        case .unsupported(let text):
            return
                "This scene needs a feature Ambient does not support yet: \(text). Supported scenes currently have one full-canvas image, optionally with the verified water-flow effect."
        }
    }
}
struct BinaryReader {
    let data: Data
    var position = 0
    mutating func bytes(_ count: Int) throws -> Data {
        guard count >= 0, position <= data.count, count <= data.count - position else {
            throw SceneError.invalid("truncated data")
        }
        defer { position += count }
        return data.subdata(in: position..<position + count)
    }
    mutating func skip(_ count: Int) throws {
        guard count >= 0, position <= data.count, count <= data.count - position else {
            throw SceneError.invalid("truncated data")
        }
        position += count
    }
    mutating func uint() throws -> UInt32 {
        guard position <= data.count - 4 else { throw SceneError.invalid("truncated integer") }
        let value = data.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: position, as: UInt32.self)
        }
        position += 4
        return UInt32(littleEndian: value)
    }
    mutating func countedString() throws -> String {
        let count = Int(try uint())
        guard count > 0, count <= 4096, let value = String(data: try bytes(count), encoding: .utf8)
        else { throw SceneError.invalid("invalid string") }
        return value
    }
    mutating func nullString() throws -> String {
        var result: [UInt8] = []
        for _ in 0..<16 {
            let byte = try bytes(1)[0]
            if byte == 0 { return String(decoding: result, as: UTF8.self) }
            result.append(byte)
        }
        throw SceneError.invalid("unterminated signature")
    }
}
struct ScenePackage {
    let data: Data
    let version: String
    private let payloadOffset: Int
    private let entries: [String: Range<Int>]
    var entryNames: [String] { entries.keys.sorted() }
    init(url: URL) throws {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= 512 * 1024 * 1024 else {
            throw SceneError.invalid("archive exceeds the 512 MiB input limit")
        }
        try self.init(data: Data(contentsOf: url, options: .mappedIfSafe))
    }
    init(data: Data) throws {
        guard data.count <= 512 * 1024 * 1024 else { throw SceneError.invalid("archive too large") }
        var reader = BinaryReader(data: data)
        let signature = try reader.countedString()
        guard signature.count == 8, signature.hasPrefix("PKGV"),
            let versionNumber = Int(signature.suffix(4)), (1...24).contains(versionNumber)
        else { throw SceneError.unsupported("archive version \(signature)") }
        let count = Int(try reader.uint())
        guard (1...10000).contains(count) else { throw SceneError.invalid("entry count") }
        var table: [String: Range<Int>] = [:]
        for _ in 0..<count {
            let name = try reader.countedString()
            guard Self.safePath(name), table[name] == nil else {
                throw SceneError.invalid("unsafe or duplicate archive path")
            }
            let offset = Int(try reader.uint())
            let size = Int(try reader.uint())
            guard offset <= data.count, size <= data.count - offset else {
                throw SceneError.invalid("entry range")
            }
            table[name] = offset..<offset + size
        }
        for range in table.values where range.upperBound > data.count - reader.position {
            throw SceneError.invalid("entry exceeds archive")
        }
        self.data = data
        version = signature
        payloadOffset = reader.position
        entries = table
    }
    static func safePath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.contains("\\") && !path.contains(":")
            && !path.contains("\0")
            && !path.split(separator: "/", omittingEmptySubsequences: false).contains(where: {
                $0 == ".." || $0 == "." || $0.isEmpty
            })
    }
    func entry(_ path: String, limit: Int = 128 * 1024 * 1024) throws -> Data {
        guard Self.safePath(path), let range = entries[path] else {
            throw SceneError.invalid("missing asset \(path)")
        }
        guard range.count <= limit else { throw SceneError.invalid("asset exceeds memory limit") }
        return data.subdata(in: payloadOffset + range.lowerBound..<payloadOffset + range.upperBound)
    }
    func json(_ path: String) throws -> [String: Any] {
        guard
            let object = try JSONSerialization.jsonObject(with: entry(path, limit: 2 * 1024 * 1024))
                as? [String: Any]
        else { throw SceneError.invalid("expected JSON object") }
        return object
    }
}

struct SceneTexture {
    enum Payload {
        case encoded(Data)
        case raw(Data, channels: Int)
    }
    let width: Int
    let height: Int
    let imageWidth: Int
    let imageHeight: Int
    let flags: UInt32
    let payload: Payload
    var estimatedBytes: Int { width * height * 4 }
    init(data: Data) throws {
        var reader = BinaryReader(data: data)
        guard try reader.nullString() == "TEXV0005", try reader.nullString() == "TEXI0001" else {
            throw SceneError.unsupported("texture signature")
        }
        let format = try reader.uint()
        flags = try reader.uint()
        guard flags & ~UInt32(3) == 0 else {
            throw SceneError.unsupported("animated/video/unknown texture flags")
        }
        let textureWidth = Int(try reader.uint())
        let textureHeight = Int(try reader.uint())
        imageWidth = Int(try reader.uint())
        imageHeight = Int(try reader.uint())
        _ = try reader.uint()
        guard
            [textureWidth, textureHeight, imageWidth, imageHeight].allSatisfy({
                (1...8192).contains($0)
            })
        else { throw SceneError.invalid("texture dimensions") }
        let container = try reader.nullString()
        guard ["TEXB0001", "TEXB0002", "TEXB0003"].contains(container) else {
            throw SceneError.unsupported("texture container \(container)")
        }
        guard try reader.uint() == 1 else { throw SceneError.unsupported("multi-image texture") }
        let imageFormat = container == "TEXB0003" ? try reader.uint() : UInt32.max
        guard [UInt32.max, 2, 13].contains(imageFormat) else {
            throw SceneError.unsupported("embedded texture image format \(imageFormat)")
        }
        let levels = Int(try reader.uint())
        guard (1...16).contains(levels) else { throw SceneError.invalid("mipmap count") }
        width = Int(try reader.uint())
        height = Int(try reader.uint())
        guard (1...8192).contains(width), (1...8192).contains(height),
            width * height <= 32 * 1024 * 1024, imageWidth <= width, imageHeight <= height
        else { throw SceneError.invalid("texture exceeds limits or has invalid image bounds") }
        let compressed = container == "TEXB0001" ? 0 : try reader.uint()
        let decompressed = container == "TEXB0001" ? 0 : Int(try reader.uint())
        guard compressed <= 1 else { throw SceneError.unsupported("texture compression") }
        let length = Int(try reader.uint())
        guard length > 0, length <= 128 * 1024 * 1024 else {
            throw SceneError.invalid("texture payload too large")
        }
        var pixels = try reader.bytes(length)
        if compressed == 1 {
            guard decompressed > 0, decompressed <= 128 * 1024 * 1024 else {
                throw SceneError.invalid("decompression size")
            }
            var decoded = Data(count: decompressed)
            let actual = decoded.withUnsafeMutableBytes { output in
                pixels.withUnsafeBytes { input in
                    compression_decode_buffer(
                        output.bindMemory(to: UInt8.self).baseAddress!, decompressed,
                        input.bindMemory(to: UInt8.self).baseAddress!, pixels.count, nil,
                        COMPRESSION_LZ4_RAW)
                }
            }
            guard actual == decompressed else {
                throw SceneError.invalid("LZ4 decompression failed")
            }
            pixels = decoded
        }
        if imageFormat != UInt32.max {
            payload = .encoded(pixels)
        } else {
            let channels: Int
            switch format {
            case 0: channels = 4
            case 8: channels = 2
            case 9: channels = 1
            default: throw SceneError.unsupported("DXT/BC or unknown raw texture format \(format)")
            }
            guard pixels.count == width * height * channels else {
                throw SceneError.invalid("raw texture byte count")
            }
            payload = .raw(pixels, channels: channels)
        }
        // Validate unused mip ranges without decoding or retaining them.
        if levels > 1 {
            for _ in 1..<levels {
                let w = Int(try reader.uint())
                let h = Int(try reader.uint())
                guard (1...8192).contains(w), (1...8192).contains(h) else {
                    throw SceneError.invalid("mipmap dimensions")
                }
                if container != "TEXB0001" {
                    _ = try reader.uint()
                    _ = try reader.uint()
                }
                try reader.skip(Int(try reader.uint()))
            }
        }
    }
}

struct SceneDescription {
    let width: Int
    let height: Int
    let basePath: String
    let maskPath: String?
    let phasePath: String?
    let speed: Float
    let strength: Float
    let phaseScale: Float
    var animated: Bool { maskPath != nil }
    init(package: ScenePackage) throws {
        let root = try package.json("scene.json")
        guard Set(root.keys).isSubset(of: ["version", "camera", "general", "objects"]) else {
            throw SceneError.unsupported("additional scene systems")
        }
        guard root["version"] as? Int == 1, let general = root["general"] as? [String: Any],
            let projection = general["orthogonalprojection"] as? [String: Any],
            let width = projection["width"] as? Int, let height = projection["height"] as? Int,
            (1...8192).contains(width), (1...8192).contains(height),
            width * height <= 32 * 1024 * 1024
        else { throw SceneError.unsupported("scene version or projection") }
        self.width = width
        self.height = height
        for key in ["bloom", "hdr", "cameraparallax", "camerashake"]
        where general[key] as? Bool == true { throw SceneError.unsupported(key) }
        guard let objects = root["objects"] as? [[String: Any]], objects.count == 1,
            let object = objects.first, let modelPath = object["image"] as? String
        else { throw SceneError.unsupported("multiple layers, particles, audio, or 3D objects") }
        let allowed: Set<String> = [
            "alignment", "alpha", "angles", "brightness", "color", "colorBlendMode",
            "copybackground", "effects", "id", "image", "ledsource", "locktransforms", "name",
            "origin", "parallaxDepth", "perspective", "scale", "size", "solid", "visible",
        ]
        guard Set(object.keys).isSubset(of: allowed) else {
            throw SceneError.unsupported("object scripts or additional properties")
        }
        func vector(_ value: Any?, _ expected: [Double]) -> Bool {
            guard let text = value as? String else { return false }
            let numbers = text.split(whereSeparator: { $0.isWhitespace }).compactMap { Double($0) }
            return numbers.count == expected.count
                && zip(numbers, expected).allSatisfy { $0.isFinite && abs($0 - $1) < 0.001 }
        }
        if let camera = root["camera"] as? [String: Any] {
            guard vector(camera["center"], [0, 0, -1]), vector(camera["eye"], [0, 0, 0]),
                vector(camera["up"], [0, 1, 0])
            else { throw SceneError.unsupported("custom camera") }
        }
        guard (general["zoom"] as? Double ?? 1) == 1 else {
            throw SceneError.unsupported("camera zoom")
        }
        guard vector(object["size"], [Double(width), Double(height)]),
            vector(object["origin"], [Double(width) / 2, Double(height) / 2, 0]),
            vector(object["scale"], [1, 1, 1]), vector(object["angles"], [0, 0, 0]),
            vector(object["color"], [1, 1, 1]), (object["alpha"] as? Double ?? 1) == 1,
            (object["brightness"] as? Double ?? 1) == 1,
            (object["colorBlendMode"] as? Int ?? 0) == 0,
            (object["alignment"] as? String ?? "center") == "center",
            object["perspective"] as? Bool != true, object["visible"] as? Bool != false
        else { throw SceneError.unsupported("transformed, tinted, or hidden image layers") }
        let model = try package.json(modelPath)
        guard Set(model.keys).isSubset(of: ["autosize", "material"]) else {
            throw SceneError.unsupported("custom geometry")
        }
        guard let materialPath = model["material"] as? String else {
            throw SceneError.invalid("model material")
        }
        let material = try package.json(materialPath)
        guard let passes = material["passes"] as? [[String: Any]], passes.count == 1,
            let pass = passes.first,
            ["genericimage2", "genericimage"].contains(pass["shader"] as? String ?? ""),
            let textures = pass["textures"] as? [String], textures.count == 1
        else { throw SceneError.unsupported("custom base material") }
        guard Set(material.keys).isSubset(of: ["passes"]),
            Set(pass.keys).isSubset(of: [
                "blending", "combos", "cullmode", "depthtest", "depthwrite", "shader", "textures",
            ]), ["normal", "translucent"].contains(pass["blending"] as? String ?? "normal"),
            (pass["depthtest"] as? String ?? "disabled") == "disabled",
            (pass["depthwrite"] as? String ?? "disabled") == "disabled"
        else { throw SceneError.unsupported("material blending or depth settings") }
        if let combos = pass["combos"] as? [String: Any] {
            guard Set(combos.keys).isSubset(of: ["version"]), combos["version"] as? Int == 2 else {
                throw SceneError.unsupported("material shader variants")
            }
        }
        basePath = "materials/" + textures[0] + ".tex"
        let effects = (object["effects"] as? [[String: Any]] ?? []).filter {
            $0["visible"] as? Bool != false
        }
        if effects.isEmpty {
            maskPath = nil
            phasePath = nil
            speed = 0
            strength = 0
            phaseScale = 1
            return
        }
        guard effects.count == 1, let effect = effects.first,
            effect["file"] as? String == "effects/waterflow/effect.json",
            let overrides = effect["passes"] as? [[String: Any]], overrides.count == 1,
            let effectPass = overrides.first,
            let values = effectPass["constantshadervalues"] as? [String: Any],
            Set(values.keys).isSubset(of: ["speed", "strength", "phasescale"]),
            let texturePaths = effectPass["textures"] as? [Any], texturePaths.count == 3,
            texturePaths[0] is NSNull, let mask = texturePaths[1] as? String,
            let phase = texturePaths[2] as? String
        else { throw SceneError.unsupported("effect other than the supported water-flow pass") }
        guard Set(effectPass.keys).isSubset(of: ["id", "textures", "constantshadervalues"]) else {
            throw SceneError.unsupported("water-flow shader overrides")
        }
        let effectDefinition = try package.json("effects/waterflow/effect.json")
        let waterMaterial = try package.json("materials/effects/waterflow.json")
        guard let effectPasses = effectDefinition["passes"] as? [[String: Any]],
            effectPasses.count == 1,
            effectPasses[0]["material"] as? String == "materials/effects/waterflow.json",
            let waterPasses = waterMaterial["passes"] as? [[String: Any]], waterPasses.count == 1,
            waterPasses[0]["shader"] as? String == "effects/waterflow",
            waterPasses[0]["blending"] as? String == "normal", waterPasses[0]["combos"] == nil
        else { throw SceneError.unsupported("custom water-flow material") }
        for (path, expected) in [
            (
                "shaders/effects/waterflow.vert",
                "a1a39898b3e45cae42fb9d6698515df876a38147f7763aecdf8e5886dea13dbe"
            ),
            (
                "shaders/effects/waterflow.frag",
                "95a60ddb1c1fac4e08fd36849a73e0e10bea12351ec07207e08295f1bb9bcaae"
            ),
        ] {
            guard
                let shader = String(
                    data: try package.entry(path, limit: 1024 * 1024), encoding: .utf8)
            else { throw SceneError.invalid("shader encoding") }
            let normalized = shader.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(
                in: .whitespacesAndNewlines)
            let hash = SHA256.hash(data: Data(normalized.utf8)).map { String(format: "%02x", $0) }
                .joined()
            guard hash == expected else {
                throw SceneError.unsupported("unrecognized water-flow shader variant")
            }
        }
        guard let speed = values["speed"] as? Float ?? (values["speed"] as? NSNumber)?.floatValue,
            let strength = values["strength"] as? NSNumber,
            let phaseScale = values["phasescale"] as? NSNumber
        else { throw SceneError.unsupported("dynamic water-flow parameters") }
        self.speed = speed
        self.strength = strength.floatValue
        self.phaseScale = phaseScale.floatValue
        guard
            [self.speed, self.strength, self.phaseScale].allSatisfy({
                $0.isFinite && $0 >= 0 && $0 <= 10
            })
        else { throw SceneError.invalid("effect parameters") }
        maskPath = "materials/" + mask + ".tex"
        phasePath = "materials/" + phase + ".tex"
    }
}
