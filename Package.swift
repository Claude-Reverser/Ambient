// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Ambient", platforms: [.macOS(.v14)],
    products: [.executable(name: "Ambient", targets: ["Ambient"])],
    targets: [
        .executableTarget(name: "Ambient"),
        .testTarget(name: "AmbientTests", dependencies: ["Ambient"]),
    ])
