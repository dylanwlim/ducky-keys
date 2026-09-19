// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "DuckyKeys", platforms: [.macOS(.v13)], products: [.executable(name: "DuckyKeys", targets: ["DuckyKeys"])], targets: [
    .target(name: "KeyMapping"),
    .executableTarget(name: "DuckyKeys", dependencies: ["KeyMapping"]),
    .testTarget(name: "KeyMappingTests", dependencies: ["KeyMapping"])
])
