// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SpaceRun",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "spacerun", targets: ["SpaceRun"])],
    targets: [
        .executableTarget(name: "SpaceRun"),
        .testTarget(name: "SpaceRunTests", dependencies: ["SpaceRun"])
    ]
)
