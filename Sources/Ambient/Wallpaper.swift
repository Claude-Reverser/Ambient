import Foundation

enum WallpaperKind: String, Codable { case video, image, web, scene }
struct Wallpaper: Identifiable, Codable, Hashable {
    var id = UUID()
    var title: String
    var path: String
    var root: String
    var kind: WallpaperKind
    var url: URL { URL(fileURLWithPath: path) }
}
enum ImportFailure: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case .message(let text) = self { return text }
        return nil
    }
}
enum WallpaperImporter {
    static func resolve(_ input: URL) throws -> Wallpaper {
        let input = input.standardizedFileURL.resolvingSymlinksInPath()
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: input.path, isDirectory: &directory) else {
            throw ImportFailure.message("This file is no longer available.")
        }
        var file = input
        var root = input.deletingLastPathComponent()
        var title = input.deletingPathExtension().lastPathComponent
        if directory.boolValue || input.lastPathComponent == "project.json" {
            root = directory.boolValue ? input : input.deletingLastPathComponent()
            let manifest = root.appendingPathComponent("project.json")
            if FileManager.default.fileExists(atPath: manifest.path) {
                guard
                    let json = try JSONSerialization.jsonObject(with: Data(contentsOf: manifest))
                        as? [String: Any], let entry = json["file"] as? String
                else {
                    throw ImportFailure.message("The project.json file needs a valid file entry.")
                }
                let type = (json["type"] as? String ?? "").lowercased()
                if type == "application" {
                    throw SceneError.unsupported("Windows application wallpaper")
                }
                if type == "scene" {
                    let archive = root.appendingPathComponent("scene.pkg").resolvingSymlinksInPath()
                    guard archive.path.hasPrefix(root.path + "/") else {
                        throw SceneError.invalid("archive is outside its project folder")
                    }
                    guard FileManager.default.fileExists(atPath: archive.path) else {
                        throw SceneError.unsupported("loose scene without scene.pkg")
                    }
                    return Wallpaper(
                        title: json["title"] as? String ?? root.lastPathComponent,
                        path: archive.path, root: root.path, kind: .scene)
                }
                file = root.appendingPathComponent(entry).standardizedFileURL
                    .resolvingSymlinksInPath()
                guard file.path.hasPrefix(root.path + "/") else {
                    throw ImportFailure.message("The project entry must be inside its folder.")
                }
                title = json["title"] as? String ?? root.lastPathComponent
            } else {
                file = root.appendingPathComponent("index.html")
                title = root.lastPathComponent
            }
        }
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw ImportFailure.message("The wallpaper's media file was not found.")
        }
        let kind: WallpaperKind
        switch file.pathExtension.lowercased() {
        case "mp4", "mov", "m4v": kind = .video
        case "png", "jpg", "jpeg", "heic", "tiff": kind = .image
        case "html", "htm", "gif": kind = .web
        case "pkg":
            kind = .scene
            if let bytes = try? Data(contentsOf: root.appendingPathComponent("project.json")),
                let json = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any]
            {
                title = json["title"] as? String ?? title
            }
        default:
            throw ImportFailure.message(
                "Unsupported format. Import MP4, MOV, M4V, GIF, PNG, JPEG, HEIC, TIFF, HTML, or a video/web project folder. Convert other video containers to H.264 or HEVC MP4 first."
            )
        }
        return Wallpaper(title: title, path: file.path, root: root.path, kind: kind)
    }
}
