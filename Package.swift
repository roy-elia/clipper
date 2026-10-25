// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Clipper",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Clipper", targets: ["Clipper"]), .executable(name: "clipper-mcp-stdio", targets: ["clipper-mcp-stdio"])],
    targets: [
        .target(name: "DropCore"),
        .executableTarget(name: "Clipper", dependencies: ["DropCore"]),
        .executableTarget(name: "clipper-mcp-stdio"),
        .testTarget(name: "DropCoreTests", dependencies: ["DropCore"]),
    ]
)
