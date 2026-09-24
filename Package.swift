// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "kiba-mac",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "KibaCore", targets: ["KibaCore"]),
        .executable(name: "Kiba", targets: ["KibaApp"]),
    ],
    targets: [
        .target(name: "KibaCore"),
        .executableTarget(name: "KibaApp", dependencies: ["KibaCore"]),
        .testTarget(name: "KibaCoreTests", dependencies: ["KibaCore"]),
    ],
    swiftLanguageModes: [.v6]
)
