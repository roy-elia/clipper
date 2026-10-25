// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Clipper",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Clipper", targets: ["Clipper"])],
    targets: [
        .target(name: "DropCore"),
        .executableTarget(name: "Clipper", dependencies: ["DropCore"]),
        .testTarget(name: "DropCoreTests", dependencies: ["DropCore"]),
    ]
)
