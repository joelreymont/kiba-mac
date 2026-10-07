// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "kiba-mac",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "KibaCore", targets: ["KibaCore"]),
        .executable(name: "Kiba", targets: ["KibaApp"]),
        .executable(name: "KibaCLI", targets: ["KibaCLI"]),
    ],
    targets: [
        .target(name: "KibaCore"),
        .executableTarget(name: "KibaApp", dependencies: ["KibaCore"]),
        .executableTarget(name: "KibaCLI", dependencies: ["KibaCore"]),
        .testTarget(name: "KibaCoreTests", dependencies: ["KibaCore", "KibaApp", "KibaCLI"]),
    ],
    swiftLanguageModes: [.v6]
)
